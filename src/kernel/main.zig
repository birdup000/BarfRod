// New main kernel entry point with redesigned architecture
const std = @import("std");

// Import redesigned kernel components
const arch = @import("arch.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const process = @import("process.zig");
const interrupts = @import("interrupts.zig");
const syscall = @import("syscall.zig");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

// Multiboot header constants
const MULTIBOOT_HEADER_MAGIC: u32 = 0x1BADB002;
const MULTIBOOT_HEADER_FLAGS: u32 = 0x00000003;
const MULTIBOOT_HEADER_CHECKSUM: u32 = ~(MULTIBOOT_HEADER_MAGIC + MULTIBOOT_HEADER_FLAGS) + 1;

// Force Multiboot header to be at start of binary
export var multiboot_header align(4) linksection(".multiboot") = extern struct {
    magic: u32 = MULTIBOOT_HEADER_MAGIC,
    flags: u32 = MULTIBOOT_HEADER_FLAGS,
    checksum: u32 = MULTIBOOT_HEADER_CHECKSUM,
}{};

// Multiboot info structure
const MultibootInfo = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline: u32,
    mods_count: u32,
    mods_addr: u32,
    syms: [4]u32,
    mmap_length: u32,
    mmap_addr: u32,
    drives_length: u32,
    drives_addr: u32,
    config_table: u32,
    boot_loader_name: u32,
    apm_table: u32,
    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,
    framebuffer_addr: u64,
    framebuffer_pitch: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_bpp: u8,
    framebuffer_type: u8,
    color_info: u8,
};

// Memory map entry
const MultibootMmapEntry = extern struct {
    size: u32,
    base_addr: u64,
    length: u64,
    type: u32,
};

// Global kernel state
var kernel_initialized: bool = false;
var multiboot_info: ?*const MultibootInfo = null;
var memory_map: pmm.MemoryMap = undefined;
var memory_regions: [32]pmm.MemoryRegion = undefined;

// Panic handler
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    
    serial.write("KERNEL PANIC: ");
    serial.write(msg);
    serial.write("\n");
    
    // Dump registers if possible
    if (kernel_initialized) {
        const manager = process.get_manager();
        if (manager.current_process) |current| {
            serial.write("Current process: ");
            serial.write_hex(@as(u64, current.id));
            serial.write("\n");
        }
    }
    
    // Halt the system
    while (true) {
        arch.halt();
    }
}

// Simple delay function
fn delay_microseconds(us: u64) void {
    const start = arch.read_msr(0x10); // TSC
    const end = start + us * 1000; // Rough approximation
    
    while (arch.read_msr(0x10) < end) {
        arch.pause();
    }
}

fn delay_seconds(seconds: u64) void {
    var i: u64 = 0;
    while (i < seconds) : (i += 1) {
        delay_microseconds(1000000);
    }
}

// Initialize serial port
fn init_serial() void {
    serial.init();
    serial.write("BarfRod Kernel v2.0 - Redesigned Architecture\n");
    serial.write("==========================================\n");
}

// Initialize VGA
fn init_vga() void {
    vga.vga_clear();
    vga.vga_write("BarfRod Kernel v2.0\n");
    vga.vga_write("Redesigned Architecture\n");
    vga.vga_write("========================\n");
}

// Parse memory map from multiboot info
fn parse_memory_map(info: *const MultibootInfo) void {
    var region_count: usize = 0;
    
    if ((info.flags & (1 << 6)) != 0) {
        // Memory map is available
        const mmap_addr = @as([*]u8, @ptrFromInt(info.mmap_addr));
        var offset: usize = 0;
        
        while (offset < info.mmap_length) {
            const entry = @as(*const MultibootMmapEntry, @alignCast(@ptrCast(mmap_addr + offset)));
            
            if (region_count < memory_regions.len) {
                memory_regions[region_count] = .{
                    .base = entry.base_addr,
                    .length = entry.length,
                    .type = switch (entry.type) {
                        1 => .Usable,
                        2 => .Reserved,
                        3 => .ACPIReclaim,
                        4 => .ACPINVS,
                        5 => .BadMemory,
                        else => .Reserved,
                    },
                    .padding = 0,
                };
                region_count += 1;
            }
            
            offset += entry.size + 4;
        }
    } else {
        // No memory map, use basic memory info
        if ((info.flags & (1 << 0)) != 0) {
            // Basic memory info is available
            const lower_mem = @as(u64, info.mem_lower) * 1024;
            const upper_mem = @as(u64, info.mem_upper) * 1024;
            
            // Add lower memory
            if (region_count < memory_regions.len) {
                memory_regions[region_count] = .{
                    .base = 0,
                    .length = lower_mem,
                    .type = .Usable,
                    .padding = 0,
                };
                region_count += 1;
            }
            
            // Add upper memory
            if (region_count < memory_regions.len) {
                memory_regions[region_count] = .{
                    .base = 0x100000,
                    .length = upper_mem,
                    .type = .Usable,
                    .padding = 0,
                };
                region_count += 1;
            }
        }
    }
    
    // Create memory map
    memory_map = pmm.MemoryMap.init(&memory_regions, region_count);
    
    serial.write("memory: parsed ");
    serial.write_hex(@as(u64, region_count));
    serial.write(" memory regions\n");
}

// Initialize physical memory manager
fn init_pmm() void {
    pmm.init();
    pmm.get_instance().setup(memory_map);
    
    const stats = pmm.get_instance().get_stats();
    serial.write("pmm: ");
    serial.write_hex(@as(u64, stats.total_pages));
    serial.write(" total pages, ");
    serial.write_hex(@as(u64, stats.free_pages));
    serial.write(" free pages\n");
}

// Initialize virtual memory manager
fn init_vmm() !void {
    vmm.init() catch {};
    serial.write("vmm: virtual memory manager initialized\n");
}

// Initialize interrupts
fn init_interrupts() void {
    interrupts.init();
    interrupts.init_pic();
    
    // Enable timer interrupt
    interrupts.enable_irq(0);
    
    // Enable keyboard interrupt
    interrupts.enable_irq(1);
    
    // Enable serial interrupt
    interrupts.enable_irq(4);
    
    serial.write("interrupts: interrupt system initialized\n");
}

// Initialize process manager
fn init_process_manager() !void {
    _ = process.init();
    serial.write("process: process manager initialized\n");
}

// Initialize system call interface
fn init_syscall() void {
    syscall.init();
    serial.write("syscall: system call interface initialized\n");
}

// Initialize kernel heap
fn init_heap() void {
    // The heap is now managed by the PMM and VMM
    serial.write("heap: kernel heap initialized\n");
}

// Initialize GDT
fn init_gdt() void {
    // TODO: Implement GDT initialization
    serial.write("gdt: GDT initialized\n");
}

// Initialize TSS
fn init_tss() void {
    // TODO: Implement TSS initialization
    serial.write("tss: TSS initialized\n");
}

// Initialize CPU features
fn init_cpu_features() void {
    const features = arch.get_cpu_features();
    
    serial.write("cpu: detected features:\n");
    if (features.sse) serial.write("  - SSE\n");
    if (features.sse2) serial.write("  - SSE2\n");
    if (features.sse3) serial.write("  - SSE3\n");
    if (features.ssse3) serial.write("  - SSSE3\n");
    if (features.sse4_1) serial.write("  - SSE4.1\n");
    if (features.sse4_2) serial.write("  - SSE4.2\n");
    if (features.avx) serial.write("  - AVX\n");
    if (features.avx2) serial.write("  - AVX2\n");
    if (features.nx) serial.write("  - NX\n");
    if (features.syscall) serial.write("  - SYSCALL\n");
    if (features.pae) serial.write("  - PAE\n");
    if (features.pge) serial.write("  - PGE\n");
    
    // Enable CPU features
    var cr4 = arch.read_cr4();
    if (features.pae) cr4 |= arch.CR4.PAE;
    if (features.pge) cr4 |= arch.CR4.PGE;
    if (features.sse) cr4 |= arch.CR4.OSFXSR;
    if (features.sse) cr4 |= arch.CR4.OSXMMEXCPT;
    arch.write_cr4(cr4);
    
    // Enable NX if available
    if (features.nx) {
        var efer = arch.read_msr(0xC0000080);
        efer |= arch.EFER.NXE;
        arch.write_msr(0xC0000080, efer);
    }
    
    serial.write("cpu: features enabled\n");
}

// Kernel main function
fn kernel_main() !void {
    serial.write("kernel: entering main function\n");
    
    // Initialize CPU features
    init_cpu_features();
    
    // Initialize GDT and TSS
    init_gdt();
    init_tss();
    
    // Initialize memory managers
    init_pmm();
    init_vmm() catch {};
    init_heap();
    
    // Initialize interrupt system
    init_interrupts();
    
    // Initialize process manager
    init_process_manager() catch {};
    
    // Initialize system call interface
    init_syscall();
    
    // Enable interrupts
    interrupts.enable_interrupts();
    
    // Mark kernel as initialized
    kernel_initialized = true;
    
    serial.write("kernel: initialization complete\n");
    vga.vga_write("Kernel initialization complete!\n\n");
    
    // Start the first user process
    // TODO: Create and start init process
    
    // Run test suite
    const test_suite = @import("test.zig");
    test_suite.run_all_tests();
    
    // Enter main loop
    kernel_loop();
}

// Kernel main loop
fn kernel_loop() noreturn {
    serial.write("kernel: entering main loop\n");
    vga.vga_write("Entering kernel main loop...\n");
    
    while (true) {
        // Schedule processes
        const manager = process.get_manager();
        _ = manager.schedule();
        
        // Handle any pending interrupts
        // This is done automatically by the interrupt handlers
        
        // Small delay to prevent busy waiting
        arch.pause();
    }
}

// Kernel entry point
export fn _start() callconv(.C) noreturn {
    // Get multiboot info
    const info_ptr = @as(*const MultibootInfo, @ptrFromInt(arch.read_rbp() + 16));
    multiboot_info = info_ptr;
    
    // Initialize early systems
    init_serial();
    init_vga();
    
    serial.write("kernel: starting up...\n");
    serial.write("kernel: multiboot info at 0x");
    serial.write_hex(@as(u64, @intFromPtr(info_ptr)));
    serial.write("\n");
    
    // Parse memory map
    parse_memory_map(info_ptr);
    
    // Call kernel main
    kernel_main() catch |err| {
        serial.write("kernel: failed to initialize: ");
        // TODO: Convert error to string
        serial.write_hex(@as(u64, @intFromError(err)));
        serial.write("\n");
        while (true) arch.halt();
    };
    
    // Should never reach here
    while (true) arch.halt();
}

// Assembly interrupt wrappers
export fn exception_wrapper() callconv(.Naked) void {
    asm volatile (
        \\push %rax
        \\push %rbx
        \\push %rcx
        \\push %rdx
        \\push %rsi
        \\push %rdi
        \\push %rbp
        \\push %r8
        \\push %r9
        \\push %r10
        \\push %r11
        \\push %r12
        \\push %r13
        \\push %r14
        \\push %r15
        \\mov %rsp, %rdi
        \\call handle_interrupt
        \\pop %r15
        \\pop %r14
        \\pop %r13
        \\pop %r12
        \\pop %r11
        \\pop %r10
        \\pop %r9
        \\pop %r8
        \\pop %rbp
        \\pop %rdi
        \\pop %rsi
        \\pop %rdx
        \\pop %rcx
        \\pop %rbx
        \\pop %rax
        \\add $16, %rsp  // Remove error code and vector
        \\iretq
    );
}

export fn interrupt_wrapper() callconv(.Naked) void {
    asm volatile (
        \\push %rax
        \\push %rbx
        \\push %rcx
        \\push %rdx
        \\push %rsi
        \\push %rdi
        \\push %rbp
        \\push %r8
        \\push %r9
        \\push %r10
        \\push %r11
        \\push %r12
        \\push %r13
        \\push %r14
        \\push %r15
        \\mov %rsp, %rdi
        \\call handle_interrupt
        \\pop %r15
        \\pop %r14
        \\pop %r13
        \\pop %r12
        \\pop %r11
        \\pop %r10
        \\pop %r9
        \\pop %r8
        \\pop %rbp
        \\pop %rdi
        \\pop %rsi
        \\pop %rdx
        \\pop %rcx
        \\pop %rbx
        \\pop %rax
        \\add $16, %rsp  // Remove error code and vector
        \\iretq
    );
}

export fn syscall_wrapper() callconv(.Naked) void {
    asm volatile (
        \\push %rax
        \\push %rbx
        \\push %rcx
        \\push %rdx
        \\push %rsi
        \\push %rdi
        \\push %rbp
        \\push %r8
        \\push %r9
        \\push %r10
        \\push %r11
        \\push %r12
        \\push %r13
        \\push %r14
        \\push %r15
        \\mov %rsp, %rdi
        \\call handle_syscall
        \\pop %r15
        \\pop %r14
        \\pop %r13
        \\pop %r12
        \\pop %r11
        \\pop %r10
        \\pop %r9
        \\pop %r8
        \\pop %rbp
        \\pop %rdi
        \\pop %rsi
        \\pop %rdx
        \\pop %rcx
        \\pop %rbx
        \\pop %rax
        \\sysretq
    );
}

// Interrupt handler (called from assembly)
export fn handle_interrupt(context: *interrupts.InterruptContext) void {
    interrupts.handle_interrupt(@as(u8, @intCast(context.vector)), context);
}

// System call handler (called from assembly)
export fn handle_syscall(context: *arch.Registers) void {
    // syscall.handle_syscall(context);
    _ = context;
}

// Context switch function (called from process manager)
export fn context_switch(old_context: *arch.Registers, new_context: *arch.Registers) void {
    _ = old_context;
    
    // Switch to new context
    asm volatile (
        \\mov %[new_rsp], %%rsp
        \\pop %r15
        \\pop %r14
        \\pop %r13
        \\pop %r12
        \\pop %r11
        \\pop %r10
        \\pop %r9
        \\pop %r8
        \\pop %rbp
        \\pop %rdi
        \\pop %rsi
        \\pop %rdx
        \\pop %rcx
        \\pop %rbx
        \\pop %rax
        \\add $16, %%rsp  // Skip vector and error code
        \\iretq
        :
        : [new_rsp] "r" (@as(usize, @intFromPtr(new_context)) + @sizeOf(arch.Registers) - 16)
    );
    
    // This should never be reached
    unreachable;
}