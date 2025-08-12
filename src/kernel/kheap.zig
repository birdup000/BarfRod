// New kernel heap implementation with advanced features
const std = @import("std");
const arch = @import("arch.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const spinlock = @import("spinlock.zig");

// Heap configuration
const HEAP_START: usize = 0xFFFF800000000000;
const HEAP_INITIAL_SIZE: usize = 16 * 1024 * 1024; // 16MB
const HEAP_MAX_SIZE: usize = 1024 * 1024 * 1024; // 1GB
const HEAP_ALIGNMENT: usize = 16;

// Block header for heap allocations
const BlockHeader = struct {
    size: usize,
    used: bool,
    prev: ?*BlockHeader = null,
    next: ?*BlockHeader = null,
    
    fn getPayload(self: *BlockHeader) *u8 {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(BlockHeader));
    }
    
    fn getHeader(payload: *u8) *BlockHeader {
        return @ptrFromInt(@intFromPtr(payload) - @sizeOf(BlockHeader));
    }
    
    fn getFooter(self: *BlockHeader) *BlockFooter {
        return @ptrFromInt(@intFromPtr(self) + self.size - @sizeOf(BlockFooter));
    }
};

// Block footer for heap allocations
const BlockFooter = struct {
    size: usize,
    
    fn getHeader(self: *BlockFooter) *BlockHeader {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(BlockFooter) - self.size);
    }
};

// Heap manager
pub const KernelHeap = struct {
    start: usize,
    end: usize,
    current: usize,
    first_block: ?*BlockHeader,
    lock: spinlock.Spinlock,
    initialized: bool,
    
    // Initialize the heap
    pub fn init() KernelHeap {
        return .{
            .start = HEAP_START,
            .end = HEAP_START + HEAP_INITIAL_SIZE,
            .current = HEAP_START,
            .first_block = null,
            .lock = spinlock.Spinlock.init(),
            .initialized = false,
        };
    }
    
    // Setup the heap
    pub fn setup(self: *KernelHeap) !void {
        if (self.initialized) return;
        
        // Lock the heap
        self.lock.acquire();
        defer self.lock.release();
        
        // Allocate initial memory region
        const addr_space = vmm.get_kernel_address_space();
        for (0..(HEAP_INITIAL_SIZE / arch.PAGE_SIZE)) |i| {
            const phys_addr = pmm.alloc_pages(1) orelse return error.OutOfMemory;
            const virt_addr = self.start + i * arch.PAGE_SIZE;
            try addr_space.map_page(virt_addr, phys_addr, .{
                .writable = true,
                .no_execute = false,
                .global = true,
            });
        }
        
        // Create initial free block
        const initial_block = @as(*BlockHeader, @ptrFromInt(self.start));
        initial_block.* = .{
            .size = HEAP_INITIAL_SIZE,
            .used = false,
            .prev = null,
            .next = null,
        };
        
        // Set footer
        const footer = initial_block.getFooter();
        footer.* = .{ .size = HEAP_INITIAL_SIZE };
        
        self.first_block = initial_block;
        self.current = self.start;
        self.initialized = true;
    }
    
    // Allocate memory
    pub fn alloc(self: *KernelHeap, size: usize, alignment: usize) !*u8 {
        if (!self.initialized) return error.NotInitialized;
        
        // Calculate total size needed
        const total_size = size + @sizeOf(BlockHeader) + @sizeOf(BlockFooter);
        const aligned_size = std.mem.alignForward(usize, total_size, alignment);
        
        // Lock the heap
        self.lock.acquire();
        defer self.lock.release();
        
        // Find a suitable block
        var block = self.find_best_fit(aligned_size);
        if (block == null) {
            // No suitable block found, try to expand the heap
            if (self.expand_heap(aligned_size)) {
                block = self.find_best_fit(aligned_size);
            }
            
            if (block == null) {
                return error.OutOfMemory;
            }
        }
        
        // Split the block if necessary
        const remaining_size = block.?.size - aligned_size;
        if (remaining_size > @sizeOf(BlockHeader) + @sizeOf(BlockFooter) + 16) {
            self.split_block(block.?, aligned_size);
        }
        
        // Mark block as used
        block.?.used = true;
        
        // Update footer
        const footer = block.?.getFooter();
        footer.size = block.?.size;
        
        return block.?.getPayload();
    }
    
    // Free memory
    pub fn free(self: *KernelHeap, ptr: *u8) void {
        if (!self.initialized) return;
        
        // Get block header
        const block = BlockHeader.getHeader(ptr);
        
        // Lock the heap
        self.lock.acquire();
        defer self.lock.release();
        
        // Mark block as free
        block.used = false;
        
        // Update footer
        const footer = block.getFooter();
        footer.size = block.size;
        
        // Coalesce with previous block if free
        if (block.prev != null and !block.prev.?.used) {
            self.coalesce_blocks(block.prev.?, block);
        }
        
        // Coalesce with next block if free
        if (block.next != null and !block.next.?.used) {
            self.coalesce_blocks(block, block.next.?);
        }
    }
    
    // Reallocate memory
    pub fn realloc(self: *KernelHeap, ptr: *u8, new_size: usize) !*u8 {
        if (!self.initialized) return error.NotInitialized;
        
        // Get block header
        const block = BlockHeader.getHeader(ptr);
        const old_size = block.size - @sizeOf(BlockHeader) - @sizeOf(BlockFooter);
        
        // If new size is smaller, just return the same pointer
        if (new_size <= old_size) {
            return ptr;
        }
        
        // Allocate new block
        const new_ptr = try self.alloc(new_size, HEAP_ALIGNMENT);
        
        // Copy old data to new block
        @memcpy(new_ptr, ptr[0..old_size]);
        
        // Free old block
        self.free(ptr);
        
        return new_ptr;
    }
    
    // Find best fit block
    fn find_best_fit(self: *KernelHeap, size: usize) ?*BlockHeader {
        var current = self.first_block;
        var best: ?*BlockHeader = null;
        
        while (current != null) {
            if (!current.?.used and current.?.size >= size) {
                if (best == null or current.?.size < best.?.size) {
                    best = current;
                }
            }
            current = current.?.next;
        }
        
        return best;
    }
    
    // Split a block
    fn split_block(self: *KernelHeap, block: *BlockHeader, size: usize) void {
        _ = self;
        const new_block = @as(*BlockHeader, @ptrFromInt(@intFromPtr(block) + size));
        new_block.* = .{
            .size = block.size - size,
            .used = false,
            .prev = block,
            .next = block.next,
        };
        
        // Update footer of new block
        const new_footer = new_block.getFooter();
        new_footer.* = .{ .size = new_block.size };
        
        // Update block
        block.size = size;
        block.next = new_block;
        
        // Update footer of block
        const footer = block.getFooter();
        footer.* = .{ .size = block.size };
        
        // Update next block's previous pointer
        if (new_block.next != null) {
            new_block.next.?.prev = new_block;
        }
    }
    
    // Coalesce two adjacent blocks
    fn coalesce_blocks(self: *KernelHeap, first: *BlockHeader, second: *BlockHeader) void {
        _ = self;
        // Update first block
        first.size += second.size;
        first.next = second.next;
        
        // Update footer of first block
        const footer = first.getFooter();
        footer.* = .{ .size = first.size };
        
        // Update next block's previous pointer
        if (first.next != null) {
            first.next.?.prev = first;
        }
    }
    
    // Expand the heap
    fn expand_heap(self: *KernelHeap, size: usize) bool {
        const current_end = self.end;
        const new_end = current_end + size;
        
        // Check if we've reached the maximum size
        if (new_end > HEAP_START + HEAP_MAX_SIZE) {
            return false;
        }
        
        // Allocate new pages
        const addr_space = vmm.get_kernel_address_space();
        for (0..(size / arch.PAGE_SIZE)) |i| {
            const phys_addr = pmm.alloc_pages(1) orelse return false;
            const virt_addr = current_end + i * arch.PAGE_SIZE;
            addr_space.map_page(virt_addr, phys_addr, .{
                .writable = true,
                .no_execute = false,
                .global = true,
            }) catch return false;
        }
        
        // Update heap end
        self.end = new_end;
        
        // Create new free block
        const new_block = @as(*BlockHeader, @ptrFromInt(current_end));
        new_block.* = .{
            .size = size,
            .used = false,
            .prev = null,
            .next = null,
        };
        
        // Find the last block and link it
        var last = self.first_block;
        while (last != null and last.?.next != null) {
            last = last.?.next;
        }
        
        if (last != null) {
            last.?.next = new_block;
            new_block.prev = last;
        } else {
            self.first_block = new_block;
        }
        
        // Set footer
        const footer = new_block.getFooter();
        footer.* = .{ .size = new_block.size };
        
        return true;
    }
    
    // Get heap statistics
    pub fn get_stats(self: *KernelHeap) HeapStats {
        self.lock.acquire();
        defer self.lock.release();
        
        var stats = HeapStats{
            .total_size = self.end - self.start,
            .used_size = 0,
            .free_size = 0,
            .block_count = 0,
            .used_blocks = 0,
            .free_blocks = 0,
        };
        
        var current = self.first_block;
        while (current != null) {
            stats.block_count += 1;
            if (current.?.used) {
                stats.used_size += current.?.size;
                stats.used_blocks += 1;
            } else {
                stats.free_size += current.?.size;
                stats.free_blocks += 1;
            }
            current = current.?.next;
        }
        
        return stats;
    }
};

// Heap statistics
pub const HeapStats = struct {
    total_size: usize,
    used_size: usize,
    free_size: usize,
    block_count: usize,
    used_blocks: usize,
    free_blocks: usize,
};

// Global heap instance
var global_heap: KernelHeap = undefined;

// Initialize the global heap
pub fn init() !void {
    global_heap = KernelHeap.init();
    try global_heap.setup();
}

// Allocate memory
pub fn alloc(size: usize, alignment: usize) !*u8 {
    return global_heap.alloc(size, alignment);
}

// Free memory
pub fn free(ptr: *u8) void {
    global_heap.free(ptr);
}

// Reallocate memory
pub fn realloc(ptr: *u8, new_size: usize) !*u8 {
    return global_heap.realloc(ptr, new_size);
}

// Get heap statistics
pub fn get_stats() HeapStats {
    return global_heap.get_stats();
}

// Allocator interface for Zig's standard library
pub const heap_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .free = freeFn,
    },
};

fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    return alloc(len, @as(usize, 1) << @as(usize, ptr_align)) catch return null;
}

fn resizeFn(ctx: *anyopaque, buf: [*]u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = buf_align;
    _ = ret_addr;
    return realloc(buf, new_len) catch return false;
}

fn freeFn(ctx: *anyopaque, buf: [*]u8, buf_align: u8, ret_addr: usize) void {
    _ = ctx;
    _ = buf_align;
    _ = ret_addr;
    free(buf);
}