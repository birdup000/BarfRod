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
    const pixels: [*]u8 = @as([*]u8, @ptrCast(fb.address.?));
    const bytes_per_pixel: u64 = @as(u64, fb.bpp) / 8;
    var y: u64 = 0;
    while (y < fb.height) : (y += 1) {
        var x: u64 = 0;
        while (x < fb.width) : (x += 1) {
            const offset = y * fb.pitch + x * bytes_per_pixel;
            pixels[offset + 0] = @intCast((x * 255) / fb.width);
            pixels[offset + 1] = @intCast((y * 255) / fb.height);
            pixels[offset + 2] = 0;
            if (bytes_per_pixel == 4) pixels[offset + 3] = 0;
        }
    }
}

// Entry symbol, referenced by linker
export fn _start() callconv(.C) noreturn {
    // Initialize serial first for early logs
    serial.init();
    serial.write("barfrod: entering kernel\n");

    // Add some debugging to see if we get here
    serial.write("barfrod: after serial init\n");
    serial.test_serial();

    // Load a minimal IDT so exceptions don't triple-fault
    idt.init();

    // Establish paging with higher-half mapping (identity + higher-half)
    const pml4 = setup_paging(0);
    const pml4_phys: u64 = @as(u64, @intFromPtr(pml4));
    load_cr3(pml4_phys);
    enable_paging_flags();

    // Avoid std formatting/prints entirely to prevent pulling UBSan/rodata
    _ = limine_bootloader_info_request;
    _ = limine_hhdm_request;
    _ = limine_framebuffer_request;

    if (limine_framebuffer_request.response) |fb_resp| {
        if (fb_resp.framebuffer_count > 0) {
            const fb = fb_resp.framebuffers.?[0];
            draw_gui(fb);
        }
    }

    // With asm stubs and no I/O, just halt after minimal setup.
    halt();
}
