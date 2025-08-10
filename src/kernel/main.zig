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

// Clean header imports. Avoid std in freestanding root.
const serial = @import("serial.zig");
const std = @import("std");
// Import paging module directly as 'paging'
const paging = @import("paging.zig");
const setup_paging = paging.setup_paging;
const load_cr3 = paging.load_cr3;
const enable_paging_flags = paging.enable_paging_flags;
const idt = @import("idt.zig");
const cli = @import("cli.zig");
const vga = @import("vga.zig");
// keep single builtin import at top of file only

// Multiboot info structure for GRUB
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

 // Minimal panic: use no stack trace type to satisfy toolchain without pulling std.* types
 pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
     _ = msg; _ = error_return_trace; _ = ret_addr;
     // no serial writes in panic to avoid pulling formatting/rodata
     halt();
 }

 // Simple delay function (waits for approximately the specified number of seconds)
 fn delay_seconds(seconds: u32) void {
     // This is a very rough approximation - in a real kernel you'd use a timer
     var i: u32 = 0;
     while (i < seconds * 1000000) : (i += 1) {
         // Small delay loop
         asm volatile ("nop");
     }
 }

fn halt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

// Entry symbol, referenced by linker
export fn _start() callconv(.C) noreturn {
    // Initialize serial first for early logs
    serial.init();
    serial.write("barfrod: serial initialized\n");
    serial.write("barfrod: entering kernel\n");

    // Simple VGA text output as fallback
    vga.vga_buffer[0][0] = vga.VGA_COLOR | 'B';
    vga.vga_buffer[0][1] = vga.VGA_COLOR | 'A';
    vga.vga_buffer[0][2] = vga.VGA_COLOR | 'R';
    vga.vga_buffer[0][3] = vga.VGA_COLOR | 'F';
    
    // Clear rest of first line
    var col: usize = 4;
    while (col < 80) : (col += 1) {
        vga.vga_buffer[0][col] = vga.VGA_COLOR | ' ';
    }
    
    serial.write("barfrod: VGA text output set\n");

    // Verify serial working
    serial.write("barfrod: testing serial...\n");
    serial.test_serial();
    serial.write("barfrod: serial test complete\n");
    
    serial.write("barfrod: about to initialize IDT\n");

    // Load IDT
    serial.write("barfrod: initializing IDT...\n");
    idt.init();
    serial.write("barfrod: IDT initialized\n");
    
    serial.write("barfrod: about to set up paging\n");

    // Set up paging
    serial.write("barfrod: setting up paging...\n");
    const pml4 = setup_paging(0);
    const pml4_phys: u64 = @as(u64, @intFromPtr(pml4));
    load_cr3(pml4_phys);
    enable_paging_flags();
    serial.write("barfrod: paging enabled\n");
    
    serial.write("barfrod: kernel initialization complete\n");

    serial.write("barfrod: entering main loop\n");
    
    // Wait 6 seconds before entering CLI
    serial.write("barfrod: waiting 6 seconds before CLI...\n");
    delay_seconds(6);
    serial.write("barfrod: entering CLI\n");
    
    // Initialize VGA for CLI
    vga.vga_clear();
    vga.vga_write("Kernel initialized successfully!\n");
    
    // Run interactive CLI
    cli.run_cli();
    
    // Should never reach here
    halt();
}
