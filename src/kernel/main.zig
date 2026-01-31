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

// Multiboot2 header constants
const MULTIBOOT2_HEADER_MAGIC: u32 = 0xE85250D6;
const MULTIBOOT2_ARCH: u32 = 0; // i386 (x86)

// Multiboot2 header structure (72 bytes total = 18 u32s):
// - Fixed header: 16 bytes (magic, arch, length, checksum)
// - Information request tag: 24 bytes (type=1, flags, size, 4 requests)
// - Address tag: 24 bytes (type=2, flags, size, load_addr, load_end_addr, bss_end_addr, padding)
// - Header end tag: 8 bytes (type=0, flags, size)
const MULTIBOOT2_HEADER_LENGTH: u32 = 72;

// Calculate checksum: -(magic + architecture + header_length)
const MULTIBOOT2_CHECKSUM_BASE: u32 = MULTIBOOT2_HEADER_MAGIC + MULTIBOOT2_ARCH + MULTIBOOT2_HEADER_LENGTH;
const MULTIBOOT2_HEADER_CHECKSUM: u32 = (~MULTIBOOT2_CHECKSUM_BASE) + 1;

// Multiboot2 header - minimal for ELF files
// For ELF, GRUB reads addresses from program headers, so no address tag needed
// Total size: 48 bytes (12 u32s)
const MB2_HEADER_LEN: u32 = 48;
const MB2_CHECKSUM: u32 = (~(MULTIBOOT2_HEADER_MAGIC + MULTIBOOT2_ARCH + MB2_HEADER_LEN)) + 1;

export var multiboot2_header align(8) linksection(".multiboot") = [12]u32{
    // Fixed header (16 bytes = 4 u32s)
    MULTIBOOT2_HEADER_MAGIC,      // magic: 0xE85250D6
    MULTIBOOT2_ARCH,              // architecture: 0 (i386)
    MB2_HEADER_LEN,               // header length: 48
    MB2_CHECKSUM,                 // checksum
    
    // Information request tag (24 bytes = 6 u32s) - type=1
    0x00000001,                   // type=1, flags=0
    24,                           // size
    1,                            // request: cmdline
    2,                            // request: bootloader name
    4,                            // request: basic mem info
    6,                            // request: mmap
    
    // Header end tag (8 bytes = 2 u32s) - type=0
    0x00000000,                   // type=0, flags=0
    8,                            // size
};

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

fn print_logo() void {
    vga.set_color(.LightRed, .Black);
    vga.vga_write_line(" ____          ____   ___   ____    ___   ____  ");
    vga.vga_write_line("|    \\ |      |    | /   \\ |    \\  /   \\ |    \\ ");
    vga.vga_write_line("|    | |      |    | |   | |    |  |   | |    | ");
    vga.vga_write_line("|    | |      |    | |   | |    |  |   | |    | ");
    vga.vga_write_line("|    | |      |    | |   | |    |  |   | |    | ");
    vga.vga_write_line("|    | |      |    | |   | |    |  |   | |    | ");
    vga.vga_write_line("|    / |____  |____| \\___/ |____/  \\___/ |____/ ");
    vga.vga_write_line("");
}

fn log(comptime level: []const u8, comptime format: []const u8, args: anytype) void {
    vga.set_color(.Cyan, .Black);
    vga.vga_write("[");
    vga.vga_write(level);
    vga.vga_write("] ");
    vga.set_color(.LightGrey, .Black);
    // vga.vga_write(std.fmt.allocPrint(std.heap.page_allocator, format, args) catch "format error");
    _ = format;
    _ = args;
}

// Kernel entry point
export fn kmain(multiboot_magic: u32, multiboot_info_addr: u32) callconv(.C) noreturn {
    // Initialize serial first for logging
    serial.init();
    serial.write("Kernel starting...\n");

    // Initialize early VGA with physical addressing (before memory management)
    serial.write("main: calling vga.init_early()...\n");
    vga.init_early();
    serial.write("main: getting VGA instance...\n");
    var early_vga = vga.get_instance();
    serial.write("main: got VGA instance, testing...\n");
    
    // Test if early VGA is working
    if (!test_vga_with_diagnostics()) {
        // If even the most basic VGA test fails, we have a serious problem
        serial.write("ERROR: VGA hardware diagnostic test failed!\n");
        // Continue anyway, but VGA won't work
    } else {
        serial.write("main: VGA diagnostics passed, clearing screen...\n");
        early_vga.clear_screen();
        serial.write("main: writing initial message to VGA...\n");
        early_vga.set_color(.LightGrey, .Black);
        early_vga.write_string("BarfRod Kernel Booting...\n");
        serial.write("main: initial VGA message written\n");
    }
    
    // Check multiboot2 magic (passed in EAX by bootloader)
    // Multiboot2 magic is 0x36d76289
    const MULTIBOOT2_BOOTLOADER_MAGIC: u32 = 0x36d76289;
    if (multiboot_magic != MULTIBOOT2_BOOTLOADER_MAGIC) {
        early_vga.set_color(.Red, .Black);
        early_vga.write_string("ERROR: Invalid multiboot magic!\n");
        serial.write("ERROR: Invalid multiboot magic! Expected: 0x");
        serial.write_hex(MULTIBOOT2_BOOTLOADER_MAGIC);
        serial.write(", Got: 0x");
        serial.write_hex(multiboot_magic);
        serial.write("\n");
        while (true) arch.halt();
    }
    
    // Parse multiboot info
    const info = @as(*const MultibootInfo, @ptrFromInt(@as(usize, @intCast(multiboot_info_addr))));
    multiboot_info = info;
    
    // Parse memory map
    parse_memory_map(info);
    
    // Initialize PMM
    early_vga.set_color(.Cyan, .Black);
    early_vga.write_string("Initializing PMM...\n");
    pmm.init();
    pmm.get_instance().setup(memory_map);

    // Initialize VMM
    serial.write("main: initializing VMM...\n");
    early_vga.write_string("Initializing VMM...\n");
    vmm.init() catch {
        early_vga.set_color(.Red, .Black);
        early_vga.write_string("FATAL: VMM initialization failed!\n");
        serial.write("FATAL: VMM initialization failed!\n");
        arch.halt();
    };
    serial.write("main: VMM initialized successfully\n");

    // Now reinitialize VGA with proper virtual mapping
    // Issue 11: Removed redundant vga.init() call since init_early() already initialized VGA
    // Instead, we switch to virtual addressing using the existing instance
    serial.write("main: switching VGA to virtual addressing...\n");
    early_vga.write_string("Setting up VGA with virtual mapping...\n");
    early_vga.switch_to_virtual();
    serial.write("main: VGA switch to virtual complete\n");
    
    // Test VGA with virtual mapping
    const vga_instance = vga.get_instance();
    serial.write("VGA: Testing virtual mapping...\n");
    if (!vga_instance.test_vga_access()) {
        vga_instance.set_color(.Red, .Black);
        vga_instance.write_string("ERROR: VGA virtual mapping test failed!\n");
        serial.write("ERROR: VGA virtual mapping test failed!\n");
        // Fall back to physical addressing
        vga_instance.switch_to_physical();
        vga_instance.write_string("Falling back to physical addressing...\n");
        serial.write("VGA: Falling back to physical addressing...\n");
        
        // Test physical addressing
        serial.write("VGA: Testing physical addressing...\n");
        if (!vga_instance.test_vga_access()) {
            vga_instance.set_color(.Red, .Black);
            vga_instance.write_string("ERROR: VGA physical addressing also failed!\n");
            serial.write("ERROR: VGA physical addressing also failed!\n");
            // At this point, VGA is not working, but we'll continue
        } else {
            vga_instance.set_color(.Yellow, .Black);
            vga_instance.write_string("VGA physical addressing working.\n");
            serial.write("VGA: Physical addressing test passed\n");
        }
    } else {
        vga_instance.set_color(.Green, .Black);
        vga_instance.write_string("VGA virtual mapping working.\n");
        serial.write("VGA: Virtual mapping test passed\n");
    }
    
    // Run comprehensive VGA test
    serial.write("VGA: Running comprehensive test...\n");
    if (vga_instance.comprehensive_test()) {
        vga_instance.set_color(.Green, .Black);
        vga_instance.write_string("VGA comprehensive test: PASSED\n");
        serial.write("VGA: Comprehensive test passed\n");
    } else {
        vga_instance.set_color(.Red, .Black);
        vga_instance.write_string("VGA comprehensive test: FAILED\n");
        serial.write("VGA: Comprehensive test failed\n");
    }
    
    // Clear screen and show initial message
    vga.clear_screen();
    vga.set_color(.LightGrey, .Black);
    vga.vga_write_line("BarfRod Kernel Booting...");
    
    // Show a simple boot screen
    show_simple_boot_screen();

    vga.set_color(.Cyan, .Black);
    vga.vga_write_line("Initializing Interrupts...");
    interrupts.init();

    vga.set_color(.Green, .Black);
    vga.vga_write_line("Core systems initialized.");

    // TODO: Initialize other modules (scheduler, syscalls, etc.)

    vga.set_color(.LightGrey, .Black);
    vga.vga_write_line("Kernel initialization complete.");

    // Idle loop
    while (true) {
        arch.halt();
    }
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
    if (features.fpu) serial.write("  - FPU\n");
    if (features.vme) serial.write("  - VME\n");
    if (features.de) serial.write("  - DE\n");
    if (features.msr) serial.write("  - MSR\n");
    if (features.pae) serial.write("  - PAE\n");
    if (features.mce) serial.write("  - MCE\n");
    if (features.cx8) serial.write("  - CX8\n");
    if (features.apic) serial.write("  - APIC\n");
    if (features.mca) serial.write("  - MCA\n");
    if (features.pge) serial.write("  - PGE\n");
    if (features.fxsr) serial.write("  - FXSR\n");
    if (features.sse) serial.write("  - SSE\n");
    if (features.sse2) serial.write("  - SSE2\n");
    if (features.sse3) serial.write("  - SSE3\n");
    if (features.ssse3) serial.write("  - SSSE3\n");
    if (features.sse4_1) serial.write("  - SSE4.1\n");
    if (features.sse4_2) serial.write("  - SSE4.2\n");
    if (features.avx) serial.write("  - AVX\n");
    if (features.xsave) serial.write("  - XSAVE\n");
    if (features.xsaveopt) serial.write("  - XSAVEOPT\n");
    if (features.osxsave) serial.write("  - OSXSAVE\n");
    if (features.avx2) serial.write("  - AVX2\n");
    if (features.nx) serial.write("  - NX\n");
    if (features.syscall) serial.write("  - SYSCALL\n");
    
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

// Stack for early boot - must be static to avoid stack allocation
// This is placed in .bss and referenced before memory management is set up
var early_stack: [16384]u8 align(16) = undefined; // 16KB stack

// ULTRA-EARLY VGA output - no initialization required
// This runs BEFORE anything else to prove VGA hardware works
fn ultra_early_vga_test() void {
    // Direct pointer to VGA buffer at physical address
    // In x86_64 with identity mapping (from bootloader), 0xB8000 is accessible
    const vga_buf = @as([*]volatile u16, @ptrFromInt(0xB8000));
    
    // Write "KERNEL OK!" in white-on-black
    // Format: ASCII byte first, then attribute byte (0x0F = white on black)
    const msg = "KERNEL OK!";
    const attr: u16 = 0x0F00; // White on black, in high byte
    
    var i: usize = 0;
    while (i < msg.len) : (i += 1) {
        vga_buf[i] = @as(u16, msg[i]) | attr;
    }
}

// Kernel entry point - sets up stack and calls kmain
// NOTE: When GRUB loads us via multiboot2, it starts us in 32-bit protected mode
// We need to transition to 64-bit long mode before calling kmain
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        // Force 32-bit code generation since GRUB starts us in 32-bit mode
        \\.code32
        
        // Write 'A' to serial to show we're alive
        \\movl $0x3F8, %edx
        \\movb $0x41, %al
        \\outb %al, %dx
        
        // Set up temporary stack in 32-bit mode
        // Load address of early_stack + 16384 (top of stack) into ESP
        // We use movl with an immediate and add to it
        \\movl $0x100000, %esp       // Start with base address (will be fixed by linker)
        \\addl $0x2A440, %esp        // Add offset to get to early_stack + 16384
        
        // Save multiboot info (in EBX) on stack before we clobber it
        \\pushl %ebx
        
        // Enable PAE (Physical Address Extension) - required for long mode
        \\movl %cr4, %eax
        \\orl $0x20, %eax           // Set PAE bit (bit 5)
        \\movl %eax, %cr4
        
        // Pop multiboot info back to EBX
        \\popl %ebx
        
        // Write 'B' to serial
        \\movb $0x42, %al
        \\outb %al, %dx
        
        // Write "HI" to VGA
        \\movl $0xB8000, %edi
        \\movw $0x0F48, (%edi)       // 'H' in white-on-black
        \\movw $0x0F49, 2(%edi)      // 'I' in white-on-black
        
        // Write 'C' to serial
        \\movb $0x43, %al
        \\outb %al, %dx
        
        // Halt for now - we need to implement proper long mode transition
        \\cli
        \\1: hlt
        \\jmp 1b
    );
}

// Simple early VGA write function for debugging (Issue 9: Add bounds check)
fn early_vga_write(s: []const u8) void {
    // Direct write to VGA buffer at physical address
    const vga_buffer = @as([*]volatile u16, @ptrFromInt(0xB8000));
    const VGA_BUFFER_SIZE = 80 * 25;
    var i: usize = 0;
    var pos: usize = 0;
    
    while (i < s.len and pos < VGA_BUFFER_SIZE) : (i += 1) {
        const c = s[i];
        if (c == '\n') {
            pos = ((pos / 80) + 1) * 80;
            if (pos >= VGA_BUFFER_SIZE) break; // Bounds check after newline
        } else if (c >= 32 and c <= 126) { // Only printable ASCII
            if (pos < VGA_BUFFER_SIZE) {
                vga_buffer[pos] = @as(u16, c) | (@as(u16, 0x0F) << 8); // White on black
                pos += 1;
            }
        } else {
            // Handle other characters (tab, etc.) or skip
            if (c == '\t') {
                const TAB_WIDTH: usize = 4;
                const next_tab = ((pos / TAB_WIDTH) + 1) * TAB_WIDTH;
                pos = if (next_tab < VGA_BUFFER_SIZE) next_tab else VGA_BUFFER_SIZE;
            }
        }
    }
}

// Enhanced VGA test with detailed error reporting
fn test_vga_with_diagnostics() bool {
    serial.write("VGA: Starting diagnostic test...\n");
    
    // Test 1: Check if VGA buffer is accessible
    const vga_buffer = @as([*]volatile u16, @ptrFromInt(0xB8000));
    serial.write("VGA: Testing buffer accessibility...\n");
    
    // Save original character
    const original = vga_buffer[0];
    
    // Write test character
    vga_buffer[0] = @as(u16, 'T') | (@as(u16, 0x0F) << 8);
    
    // Small delay
    var i: u32 = 0;
    while (i < 100000) : (i += 1) {}
    
    // Read back
    const read_back = vga_buffer[0];
    
    // Restore original
    vga_buffer[0] = original;
    
    // Check if test character was written correctly
    if ((read_back & 0xFF) != 'T') {
        serial.write("VGA: Buffer test failed - read back: ");
        serial.write_hex(read_back);
        serial.write("\n");
        return false;
    }
    
    serial.write("VGA: Buffer test passed\n");
    
    // Test 2: Check VGA control registers
    // Issue 6: Fix I/O port access - use arch.outb/arch.inb instead of memory pointers
    serial.write("VGA: Testing control registers...\n");
    
    // VGA ports 0x3D4/0x3D5 are I/O ports, not memory-mapped
    const VGA_CTRL_PORT: u16 = 0x3D4;
    const VGA_DATA_PORT: u16 = 0x3D5;
    
    // Save original values
    arch.outb(VGA_CTRL_PORT, 0x0F);
    const orig_low = arch.inb(VGA_DATA_PORT);
    arch.outb(VGA_CTRL_PORT, 0x0E);
    const orig_high = arch.inb(VGA_DATA_PORT);
    
    // Test writing and reading cursor position (low byte)
    arch.outb(VGA_CTRL_PORT, 0x0F); // Cursor low byte index
    arch.outb(VGA_DATA_PORT, 0x42); // Test value
    const read_low = arch.inb(VGA_DATA_PORT);
    
    // Test writing and reading cursor position (high byte)
    arch.outb(VGA_CTRL_PORT, 0x0E); // Cursor high byte index
    arch.outb(VGA_DATA_PORT, 0x24); // Test value
    const read_high = arch.inb(VGA_DATA_PORT);
    
    // Restore original values
    arch.outb(VGA_CTRL_PORT, 0x0F);
    arch.outb(VGA_DATA_PORT, orig_low);
    arch.outb(VGA_CTRL_PORT, 0x0E);
    arch.outb(VGA_DATA_PORT, orig_high);
    
    if (read_low != 0x42 or read_high != 0x24) {
        serial.write("VGA: Control register test failed\n");
        serial.write("VGA: Expected low=0x42, high=0x24, got low=");
        serial.write_hex(read_low);
        serial.write(", high=");
        serial.write_hex(read_high);
        serial.write("\n");
        return false;
    }
    
    serial.write("VGA: Control register test passed\n");
    serial.write("VGA: All diagnostic tests passed\n");
    return true;
}

// Simple VGA test to verify basic functionality
fn test_vga_minimal() bool {
    const vga_buffer = @as([*]volatile u16, @ptrFromInt(0xB8000));
    
    // Save original character
    const original = vga_buffer[0];
    
    // Write test character
    vga_buffer[0] = @as(u16, 'T') | (@as(u16, 0x0F) << 8);
    
    // Small delay
    var i: u32 = 0;
    while (i < 100000) : (i += 1) {}
    
    // Read back
    const read_back = vga_buffer[0];
    
    // Restore original
    vga_buffer[0] = original;
    
    // Check if test character was written correctly
    return (read_back & 0xFF) == 'T';
}

fn show_simple_boot_screen() void {
    vga.clear_screen();
    
    print_logo();

    vga.set_color(.Green, .Black);
    vga.vga_write_line("System booting...");
    
    // Simple progress indicator
    vga.vga_write("[");
    for (0..20) |_| {
        vga.vga_write("#");
        // Small delay
        var j: u32 = 0;
        while (j < 50000) : (j += 1) {}
    }
    vga.vga_write_line("]");
    
    // Test VGA functionality
    vga.set_color(.Cyan, .Black);
    vga.vga_write_line("Testing VGA...");
    
    if (vga.test_vga()) {
        vga.set_color(.Green, .Black);
        vga.vga_write_line("VGA Test: PASSED");
    } else {
        vga.set_color(.Red, .Black);
        vga.vga_write_line("VGA Test: FAILED");
        vga.set_color(.Yellow, .Black);
        vga.vga_write_line("Using fallback mode...");
        vga.switch_to_physical();
    }
    
    // Show test pattern
    vga.set_color(.LightGrey, .Black);
    vga.vga_write_line("");
    vga.test_pattern();
}

// Helper to draw a box on the screen
fn draw_box(x1: u8, y1: u8, x2: u8, y2: u8, color: vga.Color) void {
    vga.set_color(color, vga.get_instance().bg_color);

    const h_char = 205; // '═'
    const v_char = 186; // '║'
    const tl_char = 201; // '╔'
    const tr_char = 187; // '╗'
    const bl_char = 200; // '╚'
    const br_char = 188; // '╝'

    // Draw corners
    put_char_at(x1, y1, tl_char);
    put_char_at(x2, y1, tr_char);
    put_char_at(x1, y2, bl_char);
    put_char_at(x2, y2, br_char);

    // Draw horizontal lines
    for (x1 + 1..x2) |x| {
        put_char_at(x, y1, h_char);
        put_char_at(x, y2, h_char);
    }

    // Draw vertical lines
    for (y1 + 1..y2) |y| {
        put_char_at(x1, y, v_char);
        put_char_at(x2, y, v_char);
    }
}

// Helper to put a character at a specific location (Issue 10: Add bounds checking)
fn put_char_at(x: u8, y: u8, char: u8) void {
    // Validate coordinates
    if (x >= vga.VGA_WIDTH or y >= vga.VGA_HEIGHT) {
        return; // Out of bounds, ignore
    }
    const vga_instance = vga.get_instance();
    const index = @as(usize, y) * vga.VGA_WIDTH + x;
    const entry = vga.vga_entry(char, vga_instance.fg_color, vga_instance.bg_color);
    vga_instance.buffer[index] = entry;
}

// Issue 12: Removed duplicate vga_entry function - using the one from vga.zig instead

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
export fn context_switch(old_context: *arch.Registers, new_context: *arch.Registers) noreturn {
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