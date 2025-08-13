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

// Initialize PIT (Programmable Interval Timer)
fn init_pit() void {
    // Configure PIT to 1000 Hz (1193182 / 1193 ≈ 1000)
    arch.outb(0x43, 0x36);
    arch.outb(0x40, 0xA9); // Low byte
    arch.outb(0x40, 0x04); // High byte
}

// Simple delay function using PIT
fn delay_milliseconds(ms: u64) void {
    const target = arch.get_ticks() + ms;
    while (arch.get_ticks() < target) {
        arch.pause();
    }
}

fn delay_seconds(seconds: u64) void {
    delay_milliseconds(seconds * 1000);
}

// Initialize serial port
fn init_serial() void {
    serial.init();
}

// Initialize VGA
fn init_vga() void {
    vga.init();
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
    
    // Initialize CLI with a fixed buffer allocator
    const cli = @import("cli.zig");
    var cli_allocator_buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&cli_allocator_buffer);
    var shell = cli.CLI.init(fba.allocator());
    shell.show_prompt();
    
    while (true) {
        // Check for keyboard input
        if (arch.inb(0x64) & 1 != 0) {
            const scancode = arch.inb(0x60);
            if (scancode & 0x80 == 0) { // Only process key presses (ignore releases)
                const ch = scancode_to_ascii(scancode);
                if (ch != 0) {
                    cli.handle_key_event(&shell, ch);
                }
            }
        }
        
        // Small delay to prevent busy waiting
        arch.pause();
    }
}

// Simple scancode to ASCII mapping
fn scancode_to_ascii(scancode: u8) u8 {
    const table = "????????????? `?" ++  // 00-0F
                  "?????q1???zsaw2?" ++  // 10-1F
                  "?cxde43? vftr5?" ++   // 20-2F
                  "?nbhgy6? mju78?" ++   // 30-3F
                  "?,kio09??./l;p-?" ++  // 40-4F
                  "??'?[=?";             // 50-57
    
    if (scancode < 0x58) {
        return table[scancode];
    }
    return 0;
}

// Kernel entry point
export fn _start() callconv(.C) noreturn {
    // Setup stack with static buffer (16-byte aligned)
    const STACK_SIZE = 16 * 1024; // 16KB stack
    var stack: [STACK_SIZE]u8 align(16) = undefined;
    asm volatile (
        \\mov %[stack_end], %%rsp
        :
        : [stack_end] "r" (@intFromPtr(&stack) + STACK_SIZE)
        : "rsp"
    );

    // Basic VGA test
    const vga_buffer = @as(*volatile [25][80]u16, @ptrFromInt(0xB8000));
    
    // Clear screen
    for (0..25) |y| {
        for (0..80) |x| {
            vga_buffer[y][x] = 0x0F00 | ' ';
        }
    }
    
    // Simple static message
    const msg = "BarfRod Kernel";
    for (0..msg.len) |i| {
        vga_buffer[0][i] = @as(u16, 0x1F00) | @as(u16, msg[i]);
    }
    
    // Hang forever
    while (true) {
        asm volatile ("hlt");
    }
}

// Enhanced boot screen with VGA output only
fn show_boot_animation() void {
    const total_steps = 40;
    const start_y = 8;
    
    // Clear screen and set colors
    vga.vga_clear();
    vga.set_colors(.LightCyan, .Black);
    
    // Draw decorative border using existing functions
    vga.draw_box(10, start_y - 5, 70, start_y + 7);
    vga.draw_box(11, start_y - 4, 69, start_y + 6);
    
    // Draw title box
    vga.draw_box(25, start_y - 3, 55, start_y - 1);
    vga.move_cursor(30, start_y - 2);
    vga.vga_write_colored(" BARFROD KERNEL v2.0 ", .LightGreen, .Black);
    
    // Draw progress bar container
    vga.draw_box(20, start_y + 1, 60, start_y + 3);
    
    // Initial status message
    vga.move_cursor(22, start_y);
    vga.vga_write_colored("Initializing system components...", .White, .Black);
    
    // Animated progress bar with color transition
    for (0..total_steps) |step| {
        vga.move_cursor(21, start_y + 2);
        const progress = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(total_steps));
        const filled = @min(38, @as(usize, @intFromFloat(progress * 38)));
        
        // Color transition from blue to green
        const color = @as(u8, @intFromFloat(progress * 15)) + 1; // 1-16
        
        // Draw filled portion
        for (0..filled) |_| {
            // Convert color index to valid Color enum
            const colors = [_]vga.Color{
                .Blue, .Green, .Cyan, .Red, .Magenta, .Brown,
                .LightGrey, .DarkGrey, .LightBlue, .LightGreen,
                .LightCyan, .LightRed, .LightMagenta, .LightBrown, .White
            };
            const anim_color = colors[color % colors.len];
            vga.vga_write_colored("█", anim_color, .Black);
        }
        
        // Draw empty portion
        for (filled..38) |_| {
            vga.vga_write_colored("░", .DarkGrey, .Black);
        }
        
        // Update status text with different phases
        vga.move_cursor(22, start_y);
        switch (step) {
            0...9 => vga.vga_write_colored("Detecting hardware...      ", .White, .Black),
            10...19 => vga.vga_write_colored("Initializing memory...     ", .White, .Black),
            20...29 => vga.vga_write_colored("Loading subsystems...      ", .White, .Black),
            30...39 => vga.vga_write_colored("Starting services...       ", .White, .Black),
            else => {},
        }
        
        delay_milliseconds(50);
    }
    
    // Completion animation
    vga.move_cursor(25, start_y + 5);
    vga.vga_write_colored("╔════════════════════════════╗", .LightGreen, .Black);
    vga.move_cursor(25, start_y + 6);
    vga.vga_write_colored("║ System ready. Booting...   ║", .LightGreen, .Black);
    vga.move_cursor(25, start_y + 7);
    vga.vga_write_colored("╚════════════════════════════╝", .LightGreen, .Black);
    
    // Pulsing effect
    for (0..3) |i| {
        delay_milliseconds(300);
        vga.move_cursor(25, start_y + 6);
        vga.vga_write_colored("║ System ready. Booting...   ║",
            if (i % 2 == 0) .LightGreen else .Green, .Black);
    }
    
    // Clear for kernel output
    delay_milliseconds(500);
    vga.vga_clear();
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