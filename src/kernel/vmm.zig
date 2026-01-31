// Virtual Memory Manager (VMM) with advanced features
const std = @import("std");
const arch = @import("arch.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const spinlock = @import("spinlock.zig");

// Page table entry structure
pub const PageTableEntry = packed struct {
    present: u1,
    writable: u1,
    user: u1,
    write_through: u1,
    cache_disable: u1,
    accessed: u1,
    dirty: u1,
    page_size: u1,
    global: u1,
    available1: u3,
    address: u40,
    available2: u7,
    no_execute: u1,
    
    pub fn empty() PageTableEntry {
        var entry: PageTableEntry = undefined;
        @memset(@as([*]u8, @ptrCast(&entry))[0..@sizeOf(PageTableEntry)], 0);
        return entry;
    }
    
    pub fn is_present(self: *const PageTableEntry) bool {
        return self.present != 0;
    }
    
    pub fn is_writable(self: *const PageTableEntry) bool {
        return self.writable != 0;
    }
    
    pub fn is_user(self: *const PageTableEntry) bool {
        return self.user != 0;
    }
    
    pub fn is_dirty(self: *const PageTableEntry) bool {
        return self.dirty != 0;
    }
    
    pub fn is_large(self: *const PageTableEntry) bool {
        return self.page_size != 0;
    }
    
    pub fn get_address(self: *const PageTableEntry) u64 {
        return @as(u64, self.address) << 12;
    }
    
    pub fn set_address(self: *PageTableEntry, addr: u64) void {
        self.address = @as(u40, @truncate(addr >> 12));
    }
    
    pub fn set_flags(self: *PageTableEntry, flags: u64) void {
        // Create a new entry with the same address but new flags
        var new_entry = PageTableEntry.empty();
        new_entry.address = self.address;
        
        // Set individual flags
        new_entry.present = @as(u1, @truncate((flags >> 0) & 0x1));
        new_entry.writable = @as(u1, @truncate((flags >> 1) & 0x1));
        new_entry.user = @as(u1, @truncate((flags >> 2) & 0x1));
        new_entry.write_through = @as(u1, @truncate((flags >> 3) & 0x1));
        new_entry.cache_disable = @as(u1, @truncate((flags >> 4) & 0x1));
        new_entry.accessed = @as(u1, @truncate((flags >> 5) & 0x1));
        new_entry.dirty = @as(u1, @truncate((flags >> 6) & 0x1));
        new_entry.page_size = @as(u1, @truncate((flags >> 7) & 0x1));
        new_entry.global = @as(u1, @truncate((flags >> 8) & 0x1));
        new_entry.available1 = @as(u3, @truncate((flags >> 9) & 0x7));
        new_entry.available2 = @as(u7, @truncate((flags >> 12) & 0x7F));
        new_entry.no_execute = @as(u1, @truncate((flags >> 63) & 0x1));
        
        self.* = new_entry;
    }
    
    pub fn get_flags(self: *const PageTableEntry) u64 {
        var flags: u64 = 0;
        
        // Get individual flags
        flags |= @as(u64, self.present) << 0;
        flags |= @as(u64, self.writable) << 1;
        flags |= @as(u64, self.user) << 2;
        flags |= @as(u64, self.write_through) << 3;
        flags |= @as(u64, self.cache_disable) << 4;
        flags |= @as(u64, self.accessed) << 5;
        flags |= @as(u64, self.dirty) << 6;
        flags |= @as(u64, self.page_size) << 7;
        flags |= @as(u64, self.global) << 8;
        flags |= @as(u64, self.available1) << 9;
        flags |= @as(u64, self.available2) << 12;
        flags |= @as(u64, self.no_execute) << 63;
        
        return flags;
    }
};

// Page table levels
const PAGE_LEVELS = 4;
const PAGE_SHIFT = 12;
const PAGE_SIZE = 1 << PAGE_SHIFT;
const PAGE_MASK = PAGE_SIZE - 1;
const PTE_PER_TABLE = 512;
const PTE_INDEX_MASK = PTE_PER_TABLE - 1;

// Virtual memory area
pub const VmaFlags = packed struct {
    read: u1,
    write: u1,
    execute: u1,
    shared: u1,
    private: u1,
    grow_down: u1,
    grow_up: u1,
    reserved: u2,
};

pub const VmaType = enum(u8) {
    Anonymous,
    File,
    SharedMemory,
    Stack,
    Heap,
    Device,
};

pub const VirtualMemoryArea = struct {
    start: u64,
    end: u64,
    flags: VmaFlags,
    type: VmaType,
    offset: u64,
    backing_file: ?*anyopaque, // File pointer
    next: ?*VirtualMemoryArea,
    prev: ?*VirtualMemoryArea,
};

// Address space
pub const AddressSpace = struct {
    pml4: *PageTableEntry,
    vma_list: ?*VirtualMemoryArea,
    lock: spinlock.RwSpinlock,
    ref_count: u32,
    
    pub fn init() ?*AddressSpace {
        const pml4_phys = pmm.alloc_pages(1) orelse return null;
        const pml4 = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + pml4_phys));
        
        // Initialize PML4
        var i: usize = 0;
        while (i < PTE_PER_TABLE) : (i += 1) {
            @as(*[512]PageTableEntry, @ptrCast(pml4))[i] = PageTableEntry.empty();
        }
        
        // Self-map the PML4 (recursive mapping)
        const pml4_index = (arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE >> 39) & PTE_INDEX_MASK;
        @as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].set_address(pml4_phys);
        @as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].set_flags((1 << 0) | (1 << 1)); // Present | Write
        
        const addr_space = pmm.slab_alloc(AddressSpace) orelse return null;
        addr_space.* = .{
            .pml4 = pml4,
            .vma_list = null,
            .lock = spinlock.RwSpinlock.init(),
            .ref_count = 1,
        };
        
        return addr_space;
    }
    
    pub fn clone(self: *AddressSpace) ?*AddressSpace {
        const new_space = AddressSpace.init() orelse return null;
        
        // Clone VMAs
        self.lock.acquire_read();
        defer self.lock.release_read();
        
        var vma = self.vma_list;
        var prev_vma: ?*VirtualMemoryArea = null;
        
        while (vma) |current| {
            const new_vma = pmm.slab_alloc(VirtualMemoryArea) orelse {
                // Clean up and return null
                new_space.destroy();
                return null;
            };
            
            new_vma.* = current.*;
            new_vma.next = null;
            new_vma.prev = prev_vma;
            
            if (prev_vma) |prev| {
                prev.next = new_vma;
            } else {
                new_space.vma_list = new_vma;
            }
            
            prev_vma = new_vma;
            vma = current.next;
        }
        
        // Copy page tables (copy-on-write)
        // TODO: Implement CoW page table copying
        
        return new_space;
    }
    
    pub fn destroy(self: *AddressSpace) void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Free VMAs
        var vma = self.vma_list;
        while (vma) |current| {
            const next = current.next;
            pmm.slab_free(current, VirtualMemoryArea);
            vma = next;
        }
        
        // Free page tables
        // TODO: Implement page table freeing
        
        // Free the address space structure
        pmm.slab_free(self, AddressSpace);
    }
    
    pub fn add_vma(self: *AddressSpace, start: u64, end: u64, flags: VmaFlags, vma_type: VmaType) !*VirtualMemoryArea {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Check for overlap with existing VMAs
        var vma = self.vma_list;
        while (vma) |current| {
            if ((start >= current.start and start < current.end) or
                (end > current.start and end <= current.end) or
                (start <= current.start and end >= current.end)) {
                return error.Overlap;
            }
            vma = current.next;
        }
        
        // Create new VMA
        const new_vma = pmm.slab_alloc(VirtualMemoryArea) orelse return error.OutOfMemory;
        new_vma.* = .{
            .start = start,
            .end = end,
            .flags = flags,
            .type = vma_type,
            .offset = 0,
            .backing_file = null,
            .next = null,
            .prev = null,
        };
        
        // Insert into VMA list (sorted by start address)
        vma = self.vma_list;
        var prev: ?*VirtualMemoryArea = null;
        
        while (vma) |current| {
            if (start < current.start) {
                break;
            }
            prev = current;
            vma = current.next;
        }
        
        if (prev) |p| {
            p.next = new_vma;
            new_vma.prev = p;
        } else {
            self.vma_list = new_vma;
        }
        
        new_vma.next = vma;
        if (vma) |next| {
            next.prev = new_vma;
        }
        
        return new_vma;
    }
    
    pub fn remove_vma(self: *AddressSpace, vma: *VirtualMemoryArea) void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Remove from list
        if (vma.prev) |prev| {
            prev.next = vma.next;
        } else {
            self.vma_list = vma.next;
        }
        
        if (vma.next) |next| {
            next.prev = vma.prev;
        }
        
        // Unmap pages
        // TODO: Implement unmapping
        
        // Free VMA
        pmm.slab_free(vma, VirtualMemoryArea);
    }
    
    pub fn find_vma(self: *AddressSpace, addr: u64) ?*VirtualMemoryArea {
        self.lock.acquire_read();
        defer self.lock.release_read();
        
        var vma = self.vma_list;
        while (vma) |current| {
            if (addr >= current.start and addr < current.end) {
                return current;
            }
            vma = current.next;
        }
        
        return null;
    }
    
    pub fn map_page(self: *AddressSpace, vaddr: u64, paddr: u64, flags: u64) !void {
        const pml4_index = (vaddr >> 39) & PTE_INDEX_MASK;
        const pdpt_index = (vaddr >> 30) & PTE_INDEX_MASK;
        const pd_index = (vaddr >> 21) & PTE_INDEX_MASK;
        const pt_index = (vaddr >> 12) & PTE_INDEX_MASK;
        
        const pml4 = self.pml4;
        
        // Get or create PDPT
        var pdpt: *PageTableEntry = undefined;
        if (!(@as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].is_present())) {
            const pdpt_phys = pmm.alloc_pages(1) orelse return error.OutOfMemory;
            const pdpt_virt = arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + pdpt_phys;
            
            // Initialize PDPT
            var i: usize = 0;
            while (i < PTE_PER_TABLE) : (i += 1) {
                @as(*PageTableEntry, @ptrFromInt(pdpt_virt + i * @sizeOf(PageTableEntry))).* = PageTableEntry.empty();
            }
            
            @as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].set_address(pdpt_phys);
            @as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].set_flags((1 << 0) | (1 << 1)); // Present | Write
        }
        pdpt = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].get_address()));
        
        // Get or create PD
        var pd: *PageTableEntry = undefined;
        if (!(@as(*[512]PageTableEntry, @ptrCast(pdpt))[pdpt_index].is_present())) {
            const pd_phys = pmm.alloc_pages(1) orelse return error.OutOfMemory;
            const pd_virt = arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + pd_phys;
            
            // Initialize PD
            var i: usize = 0;
            while (i < PTE_PER_TABLE) : (i += 1) {
                @as(*PageTableEntry, @ptrFromInt(pd_virt + i * @sizeOf(PageTableEntry))).* = PageTableEntry.empty();
            }
            
            @as(*[512]PageTableEntry, @ptrCast(pdpt))[pdpt_index].set_address(pd_phys);
            @as(*[512]PageTableEntry, @ptrCast(pdpt))[pdpt_index].set_flags((1 << 0) | (1 << 1)); // Present | Write
        }
        pd = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pdpt))[pdpt_index].get_address()));
        
        // Get or create PT
        var pt: *PageTableEntry = undefined;
        if (!(@as(*[512]PageTableEntry, @ptrCast(pd))[pd_index].is_present())) {
            const pt_phys = pmm.alloc_pages(1) orelse return error.OutOfMemory;
            const pt_virt = arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + pt_phys;
            
            // Initialize PT
            var i: usize = 0;
            while (i < PTE_PER_TABLE) : (i += 1) {
                @as(*PageTableEntry, @ptrFromInt(pt_virt + i * @sizeOf(PageTableEntry))).* = PageTableEntry.empty();
            }
            
            @as(*[512]PageTableEntry, @ptrCast(pd))[pd_index].set_address(pt_phys);
            @as(*[512]PageTableEntry, @ptrCast(pd))[pd_index].set_flags((1 << 0) | (1 << 1)); // Present | Write
        }
        pt = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pd))[pd_index].get_address()));
        
        // Map the page
        if (!(@as(*[512]PageTableEntry, @ptrCast(pt))[pt_index].is_present())) {
            @as(*[512]PageTableEntry, @ptrCast(pt))[pt_index].set_address(paddr);
            @as(*[512]PageTableEntry, @ptrCast(pt))[pt_index].set_flags(flags);
            
            // Invalidate TLB
            arch.invlpg(vaddr);
        }
    }
    
    pub fn unmap_page(self: *AddressSpace, vaddr: u64) void {
        const pml4_index = (vaddr >> 39) & PTE_INDEX_MASK;
        const pdpt_index = (vaddr >> 30) & PTE_INDEX_MASK;
        const pd_index = (vaddr >> 21) & PTE_INDEX_MASK;
        const pt_index = (vaddr >> 12) & PTE_INDEX_MASK;
        
        const pml4 = self.pml4;
        
        if (!@as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].is_present()) return;
        
        const pdpt = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].get_address()));
        if (!@as(*[512]PageTableEntry, @ptrCast(pdpt))[pdpt_index].is_present()) return;
        
        const pd = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pdpt))[pdpt_index].get_address()));
        if (!@as(*[512]PageTableEntry, @ptrCast(pd))[pd_index].is_present()) return;
        
        const pt = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pd))[pd_index].get_address()));
        if (!@as(*[512]PageTableEntry, @ptrCast(pt))[pt_index].is_present()) return;
        
        // Free physical page
        const paddr = @as(*[512]PageTableEntry, @ptrCast(pt))[pt_index].get_address();
        pmm.free_pages(paddr, 1);
        
        // Clear PTE
        @as(*[512]PageTableEntry, @ptrCast(pt))[pt_index] = PageTableEntry.empty();
        
        // Invalidate TLB
        arch.invlpg(vaddr);
        
        // TODO: Free empty page tables
    }
    
    pub fn get_physical_address(self: *AddressSpace, vaddr: u64) ?u64 {
        const pml4_index = (vaddr >> 39) & PTE_INDEX_MASK;
        const pdpt_index = (vaddr >> 30) & PTE_INDEX_MASK;
        const pd_index = (vaddr >> 21) & PTE_INDEX_MASK;
        const pt_index = (vaddr >> 12) & PTE_INDEX_MASK;
        
        const pml4 = self.pml4;
        
        if (!@as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].is_present()) return null;
        
        const pdpt = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pml4))[pml4_index].get_address()));
        if (!@as(*[512]PageTableEntry, @ptrCast(pdpt))[pdpt_index].is_present()) return null;
        
        const pd = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pdpt))[pdpt_index].get_address()));
        if (!@as(*[512]PageTableEntry, @ptrCast(pd))[pd_index].is_present()) return null;
        
        const pt = @as(*PageTableEntry, @ptrFromInt(arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + @as(*[512]PageTableEntry, @ptrCast(pd))[pd_index].get_address()));
        if (!@as(*[512]PageTableEntry, @ptrCast(pt))[pt_index].is_present()) return null;
        
        const paddr = @as(*[512]PageTableEntry, @ptrCast(pt))[pt_index].get_address();
        return paddr + (vaddr & PAGE_MASK);
    }
};

// Virtual Memory Manager
pub const VirtualMemoryManager = struct {
    kernel_space: *AddressSpace,
    current_space: ?*AddressSpace,
    lock: spinlock.Spinlock,
    
    pub fn init() !VirtualMemoryManager {
        const kernel_space = AddressSpace.init() orelse return error.OutOfMemory;
        
        return .{
            .kernel_space = kernel_space,
            .current_space = kernel_space,
            .lock = spinlock.Spinlock.init(),
        };
    }
    
    pub fn setup_kernel_mapping(self: *VirtualMemoryManager) !void {
        // Map kernel code and data
        // TODO: Implement proper kernel mapping
        
        // Define page flags
        const FLAG_PRESENT = (1 << 0);
        const FLAG_WRITE = (1 << 1);
        const FLAG_WRITE_THROUGH = (1 << 3);
        const FLAG_CACHE_DISABLE = (1 << 4);
        
        // IMPORTANT: Set up direct mapping FIRST so that subsequent map_page calls
        // can use KERNEL_VIRT_BASE + phys_addr to access allocated page tables
        serial.write("vmm: setting up direct mapping for physical memory...\n");
        
        // Create direct mapping for physical memory access
        // NOTE: Reduced to 64MB to avoid exhausting PMM during early boot
        // The full direct mapping will be set up later when more memory is available
        const direct_map_size: u64 = 64 * 1024 * 1024; // 64MB instead of 4GB
        const direct_map_pages = direct_map_size / PAGE_SIZE;
        var i: usize = 0;
        while (i < direct_map_pages) : (i += 1) {
            const phys_addr = @as(u64, i) * PAGE_SIZE;
            const virt_addr = arch.MEMORY_LAYOUT.DIRECT_MAPPING_BASE + phys_addr;
            self.kernel_space.map_page(virt_addr, phys_addr, FLAG_PRESENT | FLAG_WRITE) catch |err| {
                serial.write("vmm: ERROR - failed to map direct mapping at page ");
                serial.write_hex(@as(u64, i));
                serial.write("\n");
                return err;
            };
        }
        serial.write("vmm: direct mapping complete (64MB)\n");
        
        // Map VGA buffer with proper flags - use write-through caching for VGA
        serial.write("vmm: mapping VGA buffer to virtual address ");
        serial.write_hex(arch.MEMORY_LAYOUT.VGA_BUFFER_VIRT);
        serial.write(" -> physical ");
        serial.write_hex(arch.MEMORY_LAYOUT.VGA_BUFFER_PHYS);
        serial.write("\n");
        
        self.kernel_space.map_page(arch.MEMORY_LAYOUT.VGA_BUFFER_VIRT, arch.MEMORY_LAYOUT.VGA_BUFFER_PHYS, FLAG_PRESENT | FLAG_WRITE | FLAG_WRITE_THROUGH) catch |err| {
            serial.write("vmm: ERROR - failed to map VGA buffer: ");
            // We can't easily print the error, but we know it failed
            serial.write("(out of memory or mapping error)\n");
            return err;
        };
        serial.write("vmm: VGA buffer mapped successfully\n");
        
        // Note: VGA control registers (0x3D4/0x3D5) are I/O ports, not memory-mapped.
        // They are accessed via inb/outb instructions, not through memory mapping.
        // Do NOT attempt to map I/O ports as memory pages - this is invalid.
        
        // Map serial ports - use uncached for hardware registers
        try self.kernel_space.map_page(arch.MEMORY_LAYOUT.SERIAL_PORT_VIRT, arch.MEMORY_LAYOUT.SERIAL_PORT_PHYS, FLAG_PRESENT | FLAG_WRITE | FLAG_CACHE_DISABLE);
        
        // Direct mapping was already set up earlier in this function
        
        // CRITICAL: Map the kernel itself at higher half virtual address
        // The kernel is loaded at 0x100000 (1MB) physical and linked at 0xFFFFFFFF80000000
        serial.write("vmm: mapping kernel to higher half...\n");
        const kernel_phys_start: u64 = 0x100000; // 1MB
        const kernel_virt_start: u64 = arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + kernel_phys_start;
        const kernel_pages: usize = 256; // Map 1MB of kernel (256 * 4KB = 1MB)
        
        var ki: usize = 0;
        while (ki < kernel_pages) : (ki += 1) {
            const kpaddr = kernel_phys_start + ki * PAGE_SIZE;
            const kvaddr = kernel_virt_start + ki * PAGE_SIZE;
            self.kernel_space.map_page(kvaddr, kpaddr, FLAG_PRESENT | FLAG_WRITE) catch |err| {
                serial.write("vmm: ERROR - failed to map kernel page ");
                serial.write_hex(@as(u64, ki));
                serial.write("\n");
                return err;
            };
        }
        serial.write("vmm: kernel mapped to higher half\n");
        
        serial.write("vmm: kernel mapping setup complete\n");
        
        // Verify VGA mapping by reading back the PML4 entry
        const pml4_index = (arch.MEMORY_LAYOUT.VGA_BUFFER_VIRT >> 39) & 0x1FF;
        const pml4_entry = @as(*[512]PageTableEntry, @ptrCast(self.kernel_space.pml4))[pml4_index];
        serial.write("vmm: VGA PML4 entry present=");
        serial.write_hex(@as(u64, pml4_entry.present));
        serial.write(" address=");
        serial.write_hex(pml4_entry.get_address());
        serial.write("\n");
    }
    
    pub fn create_address_space(self: *VirtualMemoryManager) !*AddressSpace {
        self.lock.acquire();
        defer self.lock.release();
        
        return AddressSpace.init() orelse return error.OutOfMemory;
    }
    
    pub fn switch_address_space(self: *VirtualMemoryManager, space: *AddressSpace) void {
        self.lock.acquire();
        defer self.lock.release();
        
        const pml4_phys = @intFromPtr(space.pml4) - arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE;
        arch.write_cr3(pml4_phys);
        self.current_space = space;
    }
    
    pub fn get_current_address_space(self: *VirtualMemoryManager) ?*AddressSpace {
        self.lock.acquire();
        defer self.lock.release();
        
        return self.current_space;
    }
    
    pub fn map_kernel_page(vaddr: u64, paddr: u64, flags: u64) !void {
        _ = vaddr;
        _ = paddr;
        _ = flags;
        // This function can be called without VMM instance
        // TODO: Implement direct kernel mapping
    }
    
    pub fn unmap_kernel_page(vaddr: u64) void {
        _ = vaddr;
        // TODO: Implement direct kernel unmapping
    }
    
    pub fn handle_page_fault(self: *VirtualMemoryManager, vaddr: u64, error_code: u64) void {
        _ = self;
        _ = vaddr;
        _ = error_code;
        // TODO: Implement page fault handler
        serial.write("vmm: page fault occurred\n");
        
        // For now, just halt
        while (true) {
            arch.halt();
        }
    }
};

// Global VMM instance
var vmm_instance: ?*VirtualMemoryManager = null;

pub fn init() !void {
    vmm_instance = pmm.slab_alloc(VirtualMemoryManager) orelse return error.OutOfMemory;
    vmm_instance.?.* = try VirtualMemoryManager.init();
    
    try vmm_instance.?.setup_kernel_mapping();
    
    // Activate the new page tables by switching to kernel address space
    // This is required for virtual mappings (like VGA buffer) to work
    const pml4_phys = @intFromPtr(vmm_instance.?.kernel_space.pml4) - arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE;
    arch.write_cr3(pml4_phys);
    
    // CRITICAL: Flush TLB for VGA buffer virtual address after page table switch
    // Without this, the CPU may still use cached translations
    arch.invlpg(arch.MEMORY_LAYOUT.VGA_BUFFER_VIRT);
    serial.write("vmm: TLB flushed for VGA buffer\n");
    
    serial.write("vmm: initialized and page tables activated\n");
}

pub fn get_instance() ?*VirtualMemoryManager {
    return vmm_instance;
}

pub fn get_kernel_address_space() ?*AddressSpace {
    if (vmm_instance) |instance| {
        return instance.kernel_space;
    }
    return null;
}

pub fn is_initialized() bool {
    return vmm_instance != null;
}

// Standalone page fault handler
pub fn handle_page_fault(vaddr: u64, error_code: u64) void {
    if (vmm_instance) |instance| {
        instance.handle_page_fault(vaddr, error_code);
    } else {
        serial.write("vmm: page fault occurred but VMM not initialized\n");
        while (true) {
            arch.halt();
        }
    }
}