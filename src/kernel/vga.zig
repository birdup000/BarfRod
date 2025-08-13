const std = @import("std");
const arch = @import("arch.zig");

// VGA text mode constants
pub const VGA_WIDTH = 80;
pub const VGA_HEIGHT = 25;
const VGA_BUFFER_PHYS_ADDR = arch.MEMORY_LAYOUT.VGA_BUFFER_PHYS;
const VGA_BUFFER_ADDR = arch.MEMORY_LAYOUT.VGA_BUFFER_VIRT; // Kernel virtual mapping

// VGA color constants
pub const Color = enum(u4) {
    Black = 0,
    Blue = 1,
    Green = 2,
    Cyan = 3,
    Red = 4,
    Magenta = 5,
    Brown = 6,
    LightGrey = 7,
    DarkGrey = 8,
    LightBlue = 9,
    LightGreen = 10,
    LightCyan = 11,
    LightRed = 12,
    LightMagenta = 13,
    Yellow = 14,
    White = 15,
};

// VGA driver struct
pub const VGA = struct {
    buffer: [*]volatile u16,
    cursor_x: u8,
    cursor_y: u8,
    fg_color: Color,
    bg_color: Color,
    using_virtual: bool,

    // Initialize VGA with physical address (for early boot)
    pub fn init_early() VGA {
        var vga = VGA{
            .buffer = @as([*]volatile u16, @ptrFromInt(VGA_BUFFER_PHYS_ADDR)),
            .cursor_x = 0,
            .cursor_y = 0,
            .fg_color = .LightGrey,
            .bg_color = .Black,
            .using_virtual = false,
        };
        
        vga.clear_screen();
        vga.enable_cursor(true);
        return vga;
    }

    // Initialize the VGA driver with virtual mapping
    pub fn init() VGA {
        var vga = VGA{
            .buffer = @as([*]volatile u16, @ptrFromInt(VGA_BUFFER_ADDR)),
            .cursor_x = 0,
            .cursor_y = 0,
            .fg_color = .LightGrey,
            .bg_color = .Black,
            .using_virtual = true,
        };
        
        vga.clear_screen();
        vga.enable_cursor(true);
        return vga;
    }

    // Switch to physical addressing (fallback)
    pub fn switch_to_physical(self: *VGA) void {
        self.buffer = @as([*]volatile u16, @ptrFromInt(VGA_BUFFER_PHYS_ADDR));
        self.using_virtual = false;
    }

    // Switch to virtual addressing
    pub fn switch_to_virtual(self: *VGA) void {
        self.buffer = @as([*]volatile u16, @ptrFromInt(VGA_BUFFER_ADDR));
        self.using_virtual = true;
    }

    // Clear the screen
    pub fn clear_screen(self: *VGA) void {
        const entry = vga_entry(' ', self.fg_color, self.bg_color);
        for (0..(VGA_WIDTH * VGA_HEIGHT)) |i| {
            self.buffer[i] = entry;
        }
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.update_cursor();
    }

    // Set the foreground and background colors
    pub fn set_color(self: *VGA, fg: Color, bg: Color) void {
        self.fg_color = fg;
        self.bg_color = bg;
    }

    // Put a character at a specific location
    fn put_char_at(self: *VGA, x: u8, y: u8, char: u8) void {
        const index = y * VGA_WIDTH + x;
        self.buffer[index] = vga_entry(char, self.fg_color, self.bg_color);
    }

    // Handle scrolling when the cursor reaches the end of the screen
    fn scroll(self: *VGA) void {
        // Shift all lines up by one
        for (1..VGA_HEIGHT) |y| {
            for (0..VGA_WIDTH) |x| {
                const index = y * VGA_WIDTH + x;
                const prev_index = (y - 1) * VGA_WIDTH + x;
                self.buffer[prev_index] = self.buffer[index];
            }
        }
        // Clear the last line
        const blank = vga_entry(' ', self.fg_color, self.bg_color);
        const last_line_start = (VGA_HEIGHT - 1) * VGA_WIDTH;
        for (last_line_start..(last_line_start + VGA_WIDTH)) |i| {
            self.buffer[i] = blank;
        }
        self.cursor_y = VGA_HEIGHT - 1;
    }

    // Write a single byte/character to the screen
    pub fn write_byte(self: *VGA, byte: u8) void {
        switch (byte) {
            '\n' => {
                self.cursor_x = 0;
                self.cursor_y += 1;
            },
            '\r' => {
                self.cursor_x = 0;
            },
            '\t' => {
                const TAB_WIDTH = 4;
                self.cursor_x = (self.cursor_x + TAB_WIDTH) & ~@as(u8, TAB_WIDTH - 1);
            },
            else => {
                self.put_char_at(self.cursor_x, self.cursor_y, byte);
                self.cursor_x += 1;
            },
        }

        if (self.cursor_x >= VGA_WIDTH) {
            self.cursor_x = 0;
            self.cursor_y += 1;
        }
        if (self.cursor_y >= VGA_HEIGHT) {
            self.scroll();
        }
        self.update_cursor();
    }

    // Write a string to the screen
    pub fn write_string(self: *VGA, s: []const u8) void {
        for (s) |byte| {
            self.write_byte(byte);
        }
    }

    // Update the hardware cursor position
    pub fn update_cursor(self: *VGA) void {
        const pos = self.cursor_y * VGA_WIDTH + self.cursor_x;
        arch.outb(0x3D4, 0x0F);
        arch.outb(0x3D5, @as(u8, @truncate(pos & 0xFF)));
        arch.outb(0x3D4, 0x0E);
        const pos_u16 = @as(u16, pos);
        const high_byte = @as(u8, @truncate(pos_u16 >> 8));
        arch.outb(0x3D5, high_byte);
    }

    // Enable or disable the hardware cursor
    pub fn enable_cursor(self: *VGA, enable: bool) void {
        _ = self;
        if (enable) {
            arch.outb(0x3D4, 0x0A);
            arch.outb(0x3D5, (arch.inb(0x3D5) & 0xC0) | 14);
            arch.outb(0x3D4, 0x0B);
            arch.outb(0x3D5, (arch.inb(0x3D5) & 0xE0) | @as(u8, 15));
        } else {
            arch.outb(0x3D4, 0x0A);
            arch.outb(0x3D5, 0x20);
        }
    }
    
    // Simple test to verify VGA is working
    pub fn test_vga_access(self: *VGA) bool {
        // Save original character
        const original = self.buffer[0];
        
        // Write test character
        self.buffer[0] = vga_entry('T', .White, .Black);
        
        // Small delay
        var i: u32 = 0;
        while (i < 100000) : (i += 1) {}
        
        // Read back
        const read_back = self.buffer[0];
        
        // Restore original
        self.buffer[0] = original;
        
        // Check if test character was written correctly
        return (read_back & 0xFF) == 'T';
    }
    
    // Simple test pattern
    pub fn test_pattern(self: *VGA) void {
        self.clear_screen();
        self.set_color(.White, .Black);
        self.write_string("VGA Test: OK\n");
        self.set_color(.Green, .Black);
        self.write_string("System is working\n");
    }
};

// Helper to create a 16-bit VGA entry
fn vga_entry(char: u8, fg: Color, bg: Color) u16 {
    const color = @as(u8, @intFromEnum(fg)) | (@as(u8, @intFromEnum(bg)) << 4);
    return @as(u16, char) | (@as(u16, color) << 8);
}

// Global instance of the VGA driver
var vga_instance: VGA = undefined;
var vga_initialized = false;

// Public interface
pub fn init() void {
    if (!vga_initialized) {
        vga_instance = VGA.init();
        vga_initialized = true;
        
        // Initialize with a simple test pattern
        vga_instance.set_color(.LightGrey, .Black);
        vga_instance.clear_screen();
        vga_instance.enable_cursor(true);
        vga_instance.write_string("VGA Driver Initialized\n");
    }
}

pub fn init_early() void {
    if (!vga_initialized) {
        vga_instance = VGA.init_early();
        vga_initialized = true;
        
        // Initialize with a simple test pattern
        vga_instance.set_color(.LightGrey, .Black);
        vga_instance.clear_screen();
        vga_instance.enable_cursor(true);
        vga_instance.write_string("Early VGA Initialized\n");
    }
}

pub fn get_instance() *VGA {
    if (!vga_initialized) {
        init_early(); // Default to early init for safety
    }
    return &vga_instance;
}

pub fn vga_write(s: []const u8) void {
    get_instance().write_string(s);
}

pub fn vga_write_byte(byte: u8) void {
    get_instance().write_byte(byte);
}

pub fn vga_write_line(s: []const u8) void {
    vga_write(s);
    vga_write_byte('\n');
}

pub fn clear_screen() void {
    get_instance().clear_screen();
}

pub fn set_color(fg: Color, bg: Color) void {
    get_instance().set_color(fg, bg);
}

// Switch to physical addressing (fallback)
pub fn switch_to_physical() void {
    get_instance().switch_to_physical();
}

// Switch to virtual addressing
pub fn switch_to_virtual() void {
    get_instance().switch_to_virtual();
}

// Test VGA functionality
pub fn test_vga() bool {
    return get_instance().test_vga_access();
}

// Show test pattern
pub fn test_pattern() void {
    get_instance().test_pattern();
}
