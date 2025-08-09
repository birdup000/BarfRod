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
// keep single builtin import at top of file only

// Limine boot protocol structures (minimal subset)
const limine = struct {
    pub const RequestHeader = extern struct {
        id: u64,
        revision: u64 = 0,
        response: ?*anyopaque = null,
    };

    pub const BootloaderInfoRequest = extern struct {
        header: RequestHeader = .{ .id = 0x18ad3fbd3ad94a5, .revision = 0 },
        response: ?*BootloaderInfoResponse = null,
    };
    pub const BootloaderInfoResponse = extern struct {
        revision: u64,
        name: ?[*:0]const u8,
        version: ?[*:0]const u8,
    };

    pub const HhdmRequest = extern struct {
        header: RequestHeader = .{ .id = 0x48dcf1cb8ad2c0f4, .revision = 0 },
        response: ?*HhdmResponse = null,
    };
    pub const HhdmResponse = extern struct {
        revision: u64,
        offset: u64,
    };

    pub const FramebufferRequest = extern struct {
        header: RequestHeader = .{ .id = 0xcbfe81d7c1f59d4, .revision = 0 },
        response: ?*FramebufferResponse = null,
    };
    pub const FramebufferResponse = extern struct {
        revision: u64,
        framebuffer_count: u64,
        framebuffers: ?[*]*Framebuffer,
    };
    pub const Framebuffer = extern struct {
        address: ?*anyopaque,
        width: u64,
        height: u64,
        pitch: u64,
        bpp: u16,
        memory_model: u8,
        red_mask_size: u8,
        red_mask_shift: u8,
        green_mask_size: u8,
        green_mask_shift: u8,
        blue_mask_size: u8,
        blue_mask_shift: u8,
        unused: u8,
        edid: ?*anyopaque,
        edid_size: u64,
        mode_count: u64,
        modes: ?*anyopaque,
    };

    extern "limine" var _limine_bootloader_info_request: BootloaderInfoRequest;
    extern "limine" var _limine_hhdm_request: HhdmRequest;
    extern "limine" var _limine_framebuffer_request: FramebufferRequest;
};

 // Minimal panic: use no stack trace type to satisfy toolchain without pulling std.* types
 pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
     _ = msg; _ = error_return_trace; _ = ret_addr;
     // no serial writes in panic to avoid pulling formatting/rodata
     halt();
 }

fn halt() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

// Limine requests storage: the linker will place these in a special section when referenced
export var limine_bootloader_info_request: limine.BootloaderInfoRequest linksection(".limine_reqs") = .{};
export var limine_hhdm_request: limine.HhdmRequest linksection(".limine_reqs") = .{};
export var limine_framebuffer_request: limine.FramebufferRequest linksection(".limine_reqs") = .{};

fn draw_gui(fb: *limine.Framebuffer) void {
    serial.write("barfrod: initializing framebuffer\n");
    
    if (fb.address == null) {
        serial.write("barfrod: no framebuffer address\n");
        return;
    }

    const pixels: [*]u8 = @as([*]u8, @ptrCast(fb.address.?));
    const bytes_per_pixel: u64 = @as(u64, fb.bpp) / 8;
    
    serial.write("barfrod: framebuffer ");
    serial.write_hex(@intFromPtr(fb.address.?));
    serial.write(" size=");
    serial.write_hex(fb.width);
    serial.write("x");
    serial.write_hex(fb.height);
    serial.write(" bpp=");
    serial.write_hex(fb.bpp);
    serial.write("\n");

    // Simple gradient pattern that works for RGB and BGR formats
    var y: u64 = 0;
    while (y < fb.height) : (y += 1) {
        var x: u64 = 0;
        while (x < fb.width) : (x += 1) {
            const offset = y * fb.pitch + x * bytes_per_pixel;
            const r = @as(u8, @intCast((x * 255) / fb.width));
            const g = @as(u8, @intCast((y * 255) / fb.height));
            const b = 0;
            
            // Handle different color formats
            if (fb.memory_model == 1) { // RGB
                pixels[offset + 0] = r;
                pixels[offset + 1] = g;
                pixels[offset + 2] = b;
            } else { // Assume BGR
                pixels[offset + 0] = b;
                pixels[offset + 1] = g;
                pixels[offset + 2] = r;
            }
            if (bytes_per_pixel == 4) pixels[offset + 3] = 0;
        }
    }
    serial.write("barfrod: framebuffer initialized\n");
}

// Entry symbol, referenced by linker
export fn _start() callconv(.C) noreturn {
    // Initialize serial first for early logs
    serial.init();
    serial.write("barfrod: entering kernel\n");

    // Simple VGA text output as fallback
    const vga = @as(*volatile [25][80]u16, @ptrFromInt(0xB8000));
    vga[0][0] = 0x0F00 | 'B';
    vga[0][1] = 0x0F00 | 'A';
    vga[0][2] = 0x0F00 | 'R';
    vga[0][3] = 0x0F00 | 'F';

    // Verify serial working
    serial.write("barfrod: testing serial...\n");
    serial.test_serial();
    serial.write("barfrod: serial test complete\n");

    // Load IDT
    serial.write("barfrod: initializing IDT...\n");
    idt.init();
    serial.write("barfrod: IDT initialized\n");

    // Set up paging
    serial.write("barfrod: setting up paging...\n");
    const pml4 = setup_paging(0);
    const pml4_phys: u64 = @as(u64, @intFromPtr(pml4));
    load_cr3(pml4_phys);
    enable_paging_flags();
    serial.write("barfrod: paging enabled\n");

    // Avoid std formatting/prints entirely to prevent pulling UBSan/rodata
    _ = limine_bootloader_info_request;
    _ = limine_hhdm_request;
    _ = limine_framebuffer_request;

    serial.write("barfrod: checking framebuffer...\n");
    if (limine_framebuffer_request.response == null) {
        serial.write("barfrod: no framebuffer response from bootloader\n");
    } else {
        const fb_resp = limine_framebuffer_request.response.?;
        serial.write("barfrod: framebuffer response revision ");
        serial.write_hex(fb_resp.revision);
        serial.write("\n");

        if (fb_resp.framebuffer_count == 0) {
            serial.write("barfrod: no framebuffers available\n");
        } else if (fb_resp.framebuffers == null) {
            serial.write("barfrod: framebuffers pointer is null\n");
        } else {
            const fb = fb_resp.framebuffers.?[0];
            if (fb.address == null) {
                serial.write("barfrod: framebuffer address is null\n");
            } else {
                draw_gui(fb);
                serial.write("barfrod: framebuffer initialized successfully\n");
            }
        }
    }

    serial.write("barfrod: entering main loop\n");
    
    // Main kernel loop
    while (true) {
        asm volatile ("pause");
    }
}
