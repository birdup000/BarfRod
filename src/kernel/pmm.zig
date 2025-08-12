// Advanced Physical Memory Manager (PMM) with buddy system and slab allocator
const std = @import("std");
const arch = @import("arch.zig");
const serial = @import("serial.zig");
const spinlock = @import("spinlock.zig");

// Page size and memory layout
pub const PAGE_SIZE: usize = arch.MEMORY_LAYOUT.PAGE_SIZE;
pub const PAGE_SHIFT: usize = 12;
pub const PAGE_MASK: usize = PAGE_SIZE - 1;

// Memory region types
pub const MemoryRegionType = enum(u16) {
    Usable = 1,
    Reserved = 2,
    ACPIReclaim = 3,
    ACPINVS = 4,
    BadMemory = 5,
    BootloaderReclaim = 60,
    KernelAndModules = 1010,
    Framebuffer = 1020,
};

// Memory region descriptor
pub const MemoryRegion = extern struct {
    base: u64,
    length: u64,
    type: MemoryRegionType,
    padding: u32,
};

// Memory map
pub const MemoryMap = struct {
    regions: []MemoryRegion,
    region_count: usize,
    
    pub fn init(regions: []MemoryRegion, count: usize) MemoryMap {
        return .{
            .regions = regions,
            .region_count = count,
        };
    }
    
    pub fn find_usable_region(self: *const MemoryMap, min_size: usize) ?*const MemoryRegion {
        for (self.regions[0..self.region_count]) |*region| {
            if (region.type == .Usable and region.length >= min_size) {
                return region;
            }
        }
        return null;
    }
    
    pub fn is_region_usable(self: *const MemoryMap, base: u64, length: u64) bool {
        const end = base + length;
        for (self.regions[0..self.region_count]) |region| {
            if (region.type == .Usable) {
                const region_end = region.base + region.length;
                if (base >= region.base and end <= region_end) {
                    return true;
                }
            }
        }
        return false;
    }
};

// Buddy system allocator
const BUDDY_MAX_ORDER = 11; // 2^11 = 2048 pages = 8MB max allocation
const BUDDY_MIN_ORDER = 0;  // 2^0 = 1 page = 4KB min allocation

const BuddyBlock = struct {
    order: u6,
    free: bool,
    next: ?*BuddyBlock,
    prev: ?*BuddyBlock,
};

const BuddyAllocator = struct {
    free_lists: [BUDDY_MAX_ORDER + 1]?*BuddyBlock,
    total_pages: usize,
    free_pages: usize,
    lock: spinlock.Spinlock,
    
    pub fn init() BuddyAllocator {
        return .{
            .free_lists = [_]?*BuddyBlock{null} ** (BUDDY_MAX_ORDER + 1),
            .total_pages = 0,
            .free_pages = 0,
            .lock = spinlock.Spinlock.init(),
        };
    }
    
    pub fn add_region(self: *BuddyAllocator, base: u64, length: u64) void {
        self.lock.acquire();
        defer self.lock.release();
        
        const start_page = @as(usize, @intCast(base / PAGE_SIZE));
        const end_page = @as(usize, @intCast((base + length + PAGE_SIZE - 1) / PAGE_SIZE));
        const page_count = end_page - start_page;
        
        self.total_pages += page_count;
        self.free_pages += page_count;
        
        // Add pages to buddy system in largest possible chunks
        var current = start_page;
        while (current < end_page) {
            var order: u6 = BUDDY_MAX_ORDER;
            while (order > BUDDY_MIN_ORDER) {
                const block_size = @as(usize, 1) << order;
                if (current + block_size <= end_page and
                    (current & (block_size - 1)) == 0) {
                    break;
                }
                order -= 1;
            }
            
            const block_size = @as(usize, 1) << order;
            const block = self.create_block(current, @as(u6, @truncate(order)));
            self.add_to_free_list(block, @as(u6, @truncate(order)));
            current += block_size;
        }
    }
    
    fn create_block(self: *BuddyAllocator, page: usize, order: u6) *BuddyBlock {
        _ = self;
        // Allocate metadata from a special metadata area
        // For now, we'll use a simple approach
        const block_ptr = @as(*BuddyBlock, @ptrFromInt(page * PAGE_SIZE));
        block_ptr.* = .{
            .order = order,
            .free = true,
            .next = null,
            .prev = null,
        };
        return block_ptr;
    }
    
    fn add_to_free_list(self: *BuddyAllocator, block: *BuddyBlock, order: u6) void {
        block.next = self.free_lists[order];
        if (self.free_lists[order]) |head| {
            head.prev = block;
        }
        self.free_lists[order] = block;
    }
    
    fn remove_from_free_list(self: *BuddyAllocator, block: *BuddyBlock, order: u6) void {
        if (block.prev) |prev| {
            prev.next = block.next;
        } else {
            self.free_lists[order] = block.next;
        }
        if (block.next) |next| {
            next.prev = block.prev;
        }
        block.next = null;
        block.prev = null;
    }
    
    pub fn alloc(self: *BuddyAllocator, order: u6) ?u64 {
        if (order > BUDDY_MAX_ORDER) return null;
        
        self.lock.acquire();
        defer self.lock.release();
        
        // Try to find a block of the requested size
        if (self.free_lists[order]) |block| {
            self.remove_from_free_list(block, order);
            block.free = false;
            self.free_pages -= @as(usize, 1) << order;
            return @as(u64, @intFromPtr(block)) & ~(PAGE_SIZE - 1);
        }
        
        // Try to split a larger block
        var i: u6 = order + 1;
        while (i <= BUDDY_MAX_ORDER) : (i += 1) {
            if (self.free_lists[i]) |block| {
                self.remove_from_free_list(block, i);
                
                // Split the block
                var current_order = i;
                while (current_order > order) {
                    current_order -= 1;
                    const shift_amount = @as(u6, current_order) + @as(u6, @intCast(PAGE_SHIFT));
                    const buddy_page = @as(usize, @intFromPtr(block)) ^ (@as(usize, 1) << shift_amount);
                    const buddy = self.create_block(buddy_page, @as(u6, @intCast(current_order)));
                    self.add_to_free_list(buddy, @as(u6, @intCast(current_order)));
                }
                
                block.order = order;
                block.free = false;
                self.free_pages -= @as(usize, 1) << order;
                return @as(u64, @intFromPtr(block)) & ~(PAGE_SIZE - 1);
            }
        }
        
        return null;
    }
    
    pub fn free(self: *BuddyAllocator, addr: u64, order: u6) void {
        if (order > BUDDY_MAX_ORDER) return;
        
        self.lock.acquire();
        defer self.lock.release();
        
        const block = @as(*BuddyBlock, @ptrFromInt(addr));
        block.free = true;
        self.free_pages += @as(usize, 1) << order;
        
        // Try to merge with buddy
        var current_order = order;
        while (current_order < BUDDY_MAX_ORDER) {
            const shift_amount = @as(u6, current_order) + @as(u6, @intCast(PAGE_SHIFT));
            const buddy_page = @as(usize, @intFromPtr(block)) ^ (@as(usize, 1) << shift_amount);
            const buddy = @as(*BuddyBlock, @ptrFromInt(buddy_page));
            
            if (buddy.free and buddy.order == current_order) {
                // Remove buddy from free list
                self.remove_from_free_list(buddy, current_order);
                
                // Merge blocks
                const merged_page = @min(@as(usize, @intFromPtr(block)), buddy_page);
                const merged_block = @as(*BuddyBlock, @ptrFromInt(merged_page));
                merged_block.order = current_order + 1;
                merged_block.free = true;
                
                // Continue with merged block
                current_order += 1;
                block.* = merged_block.*;
            } else {
                break;
            }
        }
        
        // Add to free list
        self.add_to_free_list(block, current_order);
    }
    
    pub fn get_free_pages(self: *const BuddyAllocator) usize {
        return self.free_pages;
    }
    
    pub fn get_total_pages(self: *const BuddyAllocator) usize {
        return self.total_pages;
    }
};

// Slab allocator for small objects
const SLAB_MIN_SIZE = 8;
const SLAB_MAX_SIZE = 8192;
const SLAB_DEFAULT_SIZE = 4096; // 4KB per slab

const SlabObject = struct {
    next: ?*SlabObject,
    prev: ?*SlabObject,
    slab: *Slab,
};

const Slab = struct {
    next: ?*Slab,
    prev: ?*Slab,
    objects: ?*SlabObject,
    free_count: usize,
    total_count: usize,
    object_size: usize,
    data: [SLAB_DEFAULT_SIZE]u8,
};

const SlabCache = struct {
    name: []const u8,
    object_size: usize,
    alignment: usize,
    slabs_full: ?*Slab,
    slabs_partial: ?*Slab,
    slabs_free: ?*Slab,
    next: ?*SlabCache,
    lock: spinlock.Spinlock,
    
    pub fn init(name: []const u8, object_size: usize, align_param: usize) SlabCache {
        return .{
            .name = name,
            .object_size = object_size,
            .alignment = align_param,
            .slabs_full = null,
            .slabs_partial = null,
            .slabs_free = null,
            .next = null,
            .lock = spinlock.Spinlock.init(),
        };
    }
    
    pub fn alloc(self: *SlabCache, buddy: *BuddyAllocator) ?*anyopaque {
        self.lock.acquire();
        defer self.lock.release();
        
        // Try partial slabs first
        if (self.slabs_partial) |slab| {
            const obj = slab.objects.?;
            slab.objects = obj.next;
            slab.free_count -= 1;
            
            if (slab.free_count == 0) {
                // Move to full list
                if (slab.prev) |prev| {
                    prev.next = slab.next;
                } else {
                    self.slabs_partial = slab.next;
                }
                if (slab.next) |next| {
                    next.prev = slab.prev;
                }
                
                slab.next = self.slabs_full;
                if (self.slabs_full) |head| {
                    head.prev = slab;
                }
                self.slabs_full = slab;
                slab.prev = null;
            }
            
            return @as(*anyopaque, @ptrCast(obj));
        }
        
        // Try free slabs
        if (self.slabs_free) |slab| {
            const obj = slab.objects.?;
            slab.objects = obj.next;
            slab.free_count -= 1;
            
            // Move to partial list
            if (slab.prev) |prev| {
                prev.next = slab.next;
            } else {
                self.slabs_free = slab.next;
            }
            if (slab.next) |next| {
                next.prev = slab.prev;
            }
            
            slab.next = self.slabs_partial;
            if (self.slabs_partial) |head| {
                head.prev = slab;
            }
            self.slabs_partial = slab;
            slab.prev = null;
            
            return @as(*anyopaque, @ptrCast(obj));
        }
        
        // Allocate new slab
        const slab_addr = buddy.alloc(0) orelse return null;
        const slab = @as(*Slab, @ptrFromInt(slab_addr));
        slab.* = .{
            .next = null,
            .prev = null,
            .objects = null,
            .free_count = 0,
            .total_count = 0,
            .object_size = self.object_size,
            .data = undefined,
        };
        
        // Initialize objects in slab
        var offset: usize = 0;
        while (offset + self.object_size <= SLAB_DEFAULT_SIZE) {
            const obj_ptr = @as(*SlabObject, @alignCast(@ptrCast(&slab.data[offset])));
            obj_ptr.* = .{
                .next = slab.objects,
                .prev = null,
                .slab = slab,
            };
            if (slab.objects) |head| {
                head.prev = obj_ptr;
            }
            slab.objects = obj_ptr;
            slab.free_count += 1;
            slab.total_count += 1;
            offset += self.object_size;
        }
        
        // Add to partial list and return first object
        slab.next = self.slabs_partial;
        if (self.slabs_partial) |head| {
            head.prev = slab;
        }
        self.slabs_partial = slab;
        
        const obj = slab.objects.?;
        slab.objects = obj.next;
        slab.free_count -= 1;
        
        return @as(*anyopaque, @ptrCast(obj));
    }
    
    pub fn free(self: *SlabCache, obj: *anyopaque) void {
        self.lock.acquire();
        defer self.lock.release();
        
        const slab_obj = @as(*SlabObject, @alignCast(@ptrCast(obj)));
        const slab = slab_obj.slab;
        
        // Add object back to slab's free list
        slab_obj.next = slab.objects;
        if (slab.objects) |head| {
            head.prev = slab_obj;
        }
        slab.objects = slab_obj;
        slab.free_count += 1;
        
        // Move slab to appropriate list
        if (slab.free_count == 1) {
            // Was full, now partial
            if (slab.prev) |prev| {
                prev.next = slab.next;
            } else {
                self.slabs_full = slab.next;
            }
            if (slab.next) |next| {
                next.prev = slab.prev;
            }
            
            slab.next = self.slabs_partial;
            if (self.slabs_partial) |head| {
                head.prev = slab;
            }
            self.slabs_partial = slab;
            slab.prev = null;
        } else if (slab.free_count == slab.total_count) {
            // Was partial, now free
            if (slab.prev) |prev| {
                prev.next = slab.next;
            } else {
                self.slabs_partial = slab.next;
            }
            if (slab.next) |next| {
                next.prev = slab.prev;
            }
            
            slab.next = self.slabs_free;
            if (self.slabs_free) |head| {
                head.prev = slab;
            }
            self.slabs_free = slab;
            slab.prev = null;
        }
    }
};

// PMM main structure
pub const PhysicalMemoryManager = struct {
    buddy: BuddyAllocator,
    slab_caches: ?*SlabCache,
    memory_map: MemoryMap,
    initialized: bool,
    
    pub fn init() PhysicalMemoryManager {
        return .{
            .buddy = BuddyAllocator.init(),
            .slab_caches = null,
            .memory_map = MemoryMap.init(undefined, 0),
            .initialized = false,
        };
    }
    
    pub fn setup(self: *PhysicalMemoryManager, memory_map: MemoryMap) void {
        self.memory_map = memory_map;
        
        // Add all usable memory regions to buddy allocator
        for (memory_map.regions[0..memory_map.region_count]) |region| {
            if (region.type == .Usable) {
                // Align to page boundaries
                const base = std.mem.alignForward(usize, @as(usize, @intCast(region.base)), PAGE_SIZE);
                const end = std.mem.alignBackward(usize, @as(usize, @intCast(region.base + region.length)), PAGE_SIZE);
                if (end > base) {
                    self.buddy.add_region(@as(u64, @intCast(base)), @as(u64, @intCast(end - base)));
                }
            }
        }
        
        // Initialize slab caches
        self.init_slab_caches();
        
        self.initialized = true;
        
        serial.write("pmm: initialized with ");
        serial.write_hex(@intCast(@as(u64, self.buddy.get_total_pages())));
        serial.write(" total pages, ");
        serial.write_hex(@intCast(@as(u64, self.buddy.get_free_pages())));
        serial.write(" free pages\n");
    }
    
    fn init_slab_caches(self: *PhysicalMemoryManager) void {
        // Create common slab cache sizes
        const sizes = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
        var prev_cache: ?*SlabCache = null;
        
        for (sizes) |size| {
            const cache = self.slab_alloc(SlabCache) orelse continue;
            cache.* = SlabCache.init("slab_cache", size, @alignOf(SlabCache));
            
            if (prev_cache) |prev| {
                prev.next = cache;
            } else {
                self.slab_caches = cache;
            }
            prev_cache = cache;
        }
    }
    
    pub fn alloc_pages(self: *PhysicalMemoryManager, count: usize) ?u64 {
        if (!self.initialized) return null;
        
        // Calculate required order
        var order: u6 = 0;
        var needed = count;
        while (needed > 1) {
            needed >>= 1;
            order += 1;
        }
        
        return self.buddy.alloc(order);
    }
    
    pub fn free_pages(self: *PhysicalMemoryManager, addr: u64, count: usize) void {
        if (!self.initialized) return;
        
        // Calculate order
        var order: u6 = 0;
        var needed = count;
        while (needed > 1) {
            needed >>= 1;
            order += 1;
        }
        
        self.buddy.free(addr, order);
    }
    
    pub fn slab_alloc(self: *PhysicalMemoryManager, comptime T: type) ?*T {
        if (!self.initialized) return null;
        
        const size = @sizeOf(T);
        _ = @alignOf(T);
        
        // Find appropriate slab cache
        var cache = self.slab_caches;
        while (cache) |c| {
            if (c.object_size >= size and c.object_size <= size * 2) {
                return @as(*T, @alignCast(@ptrCast(c.alloc(&self.buddy) orelse return null)));
            }
            cache = c.next;
        }
        
        // No suitable cache found, allocate directly from buddy
        const addr = self.buddy.alloc(0) orelse return null;
        return @as(*T, @ptrFromInt(addr));
    }
    
    pub fn slab_free(self: *PhysicalMemoryManager, ptr: *anyopaque, comptime T: type) void {
        if (!self.initialized) return;
        
        const size = @sizeOf(T);
        
        // Find appropriate slab cache
        var cache = self.slab_caches;
        while (cache) |c| {
            if (c.object_size >= size and c.object_size <= size * 2) {
                c.free(ptr);
                return;
            }
            cache = c.next;
        }
        
        // No suitable cache found, free directly to buddy
        self.buddy.free(@as(u64, @intFromPtr(ptr)), 0);
    }
    
    pub fn get_stats(self: *const PhysicalMemoryManager) struct {
        total_pages: usize,
        free_pages: usize,
        used_pages: usize,
    } {
        return .{
            .total_pages = self.buddy.get_total_pages(),
            .free_pages = self.buddy.get_free_pages(),
            .used_pages = self.buddy.get_total_pages() - self.buddy.get_free_pages(),
        };
    }
};

// Global PMM instance
var pmm_instance: PhysicalMemoryManager = undefined;

pub fn init() void {
    pmm_instance = PhysicalMemoryManager.init();
}

pub fn get_instance() *PhysicalMemoryManager {
    return &pmm_instance;
}

// Helper functions for slab allocation
pub fn slab_alloc(comptime T: type) ?*T {
    return get_instance().slab_alloc(T);
}

pub fn slab_free(ptr: *anyopaque, comptime T: type) void {
    get_instance().slab_free(ptr, T);
}

pub fn alloc_pages(count: usize) ?u64 {
    return get_instance().alloc_pages(count);
}

pub fn free_pages(addr: u64, count: usize) void {
    get_instance().free_pages(addr, count);
}