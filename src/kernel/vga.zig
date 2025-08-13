const std = @import("std");
const arch = @import("arch.zig");

// VGA text mode constants
pub const VGA_WIDTH = 80;
pub const VGA_HEIGHT = 25;
pub const vga_buffer = @as(*volatile [VGA_HEIGHT][VGA_WIDTH]u16, @ptrFromInt(0xB8000));

// VGA color constants
pub const Color = enum(u8) {
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
    LightBrown = 14,
    White = 15,
};

// VGA entry structure
pub const VGAEntry = packed struct {
    character: u8,
    foreground: u4,
    background: u4,
    
    pub fn init(ch: u8, fg: Color, bg: Color) u16 {
        return @as(u16, ch) | (@as(u16, @intFromEnum(fg)) << 8) | (@as(u16, @intFromEnum(bg)) << 12);
    }
};

// Global cursor and color state
pub var cursor_x: usize = 0;
pub var cursor_y: usize = 0;
pub var current_fg: Color = .LightGrey;
pub var current_bg: Color = .Black;

pub fn vga_write_byte(ch: u8) void {
    if (ch == '\n') {
        cursor_x = 0;
        cursor_y += 1;
        if (cursor_y >= VGA_HEIGHT) {
            scroll_screen();
            cursor_y = VGA_HEIGHT - 1;
        }
    } else if (ch == '\r') {
        cursor_x = 0;
    } else if (ch == '\t') {
        cursor_x = (cursor_x + 8) & ~@as(usize, 7);
        if (cursor_x >= VGA_WIDTH) {
            cursor_x = 0;
            cursor_y += 1;
            if (cursor_y >= VGA_HEIGHT) {
                scroll_screen();
                cursor_y = VGA_HEIGHT - 1;
            }
        }
    } else if (ch == '\x1b') {
        // Start of escape sequence - handle ANSI codes
        // For now, just ignore the escape sequence
        // TODO: Implement full ANSI escape sequence parsing
    } else {
        if (cursor_x >= VGA_WIDTH) {
            cursor_x = 0;
            cursor_y += 1;
        }
        if (cursor_y >= VGA_HEIGHT) {
            scroll_screen();
            cursor_y = VGA_HEIGHT - 1;
        }
        vga_buffer[cursor_y][cursor_x] = VGAEntry.init(ch, current_fg, current_bg);
        cursor_x += 1;
    }
    update_cursor();
}

// Helper function to scroll the screen
fn scroll_screen() void {
    // Move all lines up by one
    var row: usize = 0;
    while (row < VGA_HEIGHT - 1) : (row += 1) {
        var col: usize = 0;
        while (col < VGA_WIDTH) : (col += 1) {
            vga_buffer[row][col] = vga_buffer[row + 1][col];
        }
    }
    
    // Clear the last line
    var col: usize = 0;
    while (col < VGA_WIDTH) : (col += 1) {
        vga_buffer[VGA_HEIGHT - 1][col] = VGAEntry.init(' ', current_fg, current_bg);
    }
}

// Update hardware cursor position
fn update_cursor() void {
    const position = cursor_y * VGA_WIDTH + cursor_x;
    
    // Tell the VGA board we are setting the high cursor byte
    arch.outb(0x3D4, 0x0E);
    arch.outb(0x3D5, @as(u8, @truncate((position >> 8) & 0xFF)));
    
    // Tell the VGA board we are setting the low cursor byte
    arch.outb(0x3D4, 0x0F);
    arch.outb(0x3D5, @as(u8, @truncate(position & 0xFF)));
}

// Enable/disable cursor
pub fn set_cursor_enabled(enabled: bool) void {
    const start = if (enabled) @as(u8, 0x0E) else @as(u8, 0x20);
    const end = if (enabled) @as(u8, 0x0F) else @as(u8, 0x00);
    
    arch.outb(0x3D4, 0x0A);
    arch.outb(0x3D5, start);
    
    arch.outb(0x3D4, 0x0B);
    arch.outb(0x3D5, end);
}

// Set text colors
pub fn set_colors(fg: Color, bg: Color) void {
    current_fg = fg;
    current_bg = bg;
}

// Set foreground color
pub fn set_foreground(fg: Color) void {
    current_fg = fg;
}

// Set background color
pub fn set_background(bg: Color) void {
    current_bg = bg;
}

pub fn vga_write(s: []const u8) void {
    for (s) |ch| {
        vga_write_byte(ch);
    }
}

pub fn vga_write_line(s: []const u8) void {
    vga_write(s);
    vga_write_byte('\n');
}

// Move cursor to specific position
pub fn move_cursor(x: usize, y: usize) void {
    if (x < VGA_WIDTH and y < VGA_HEIGHT) {
        cursor_x = x;
        cursor_y = y;
        update_cursor();
    }
}

// Get current cursor position
pub fn get_cursor_position() struct { x: usize, y: usize } {
    return .{ .x = cursor_x, .y = cursor_y };
}

// Clear from cursor to end of line
pub fn clear_line() void {
    var col: usize = cursor_x;
    while (col < VGA_WIDTH) : (col += 1) {
        vga_buffer[cursor_y][col] = VGAEntry.init(' ', current_fg, current_bg);
    }
}

// Clear entire screen and reset cursor
pub fn clear_screen() void {
    vga_clear();
}

// Scroll screen by n lines
pub fn scroll_lines(lines: usize) void {
    var i: usize = 0;
    while (i < lines) : (i += 1) {
        scroll_screen();
    }
}

// Write formatted string (simple implementation)
pub fn vga_write_fmt(comptime format: []const u8, args: anytype) void {
    // Simple format implementation - just convert args to strings
    // TODO: Implement proper formatting
    _ = format;
    _ = args;
}

// Write a single character with specific colors
pub fn vga_write_char_colored(ch: u8, fg: Color, bg: Color) void {
    if (cursor_x >= VGA_WIDTH) {
        cursor_x = 0;
        cursor_y += 1;
    }
    if (cursor_y >= VGA_HEIGHT) {
        scroll_screen();
        cursor_y = VGA_HEIGHT - 1;
    }
    vga_buffer[cursor_y][cursor_x] = VGAEntry.init(ch, fg, bg);
    cursor_x += 1;
    update_cursor();
}

// Write a string with specific colors
pub fn vga_write_colored(s: []const u8, fg: Color, bg: Color) void {
    const old_fg = current_fg;
    const old_bg = current_bg;
    
    set_colors(fg, bg);
    vga_write(s);
    
    set_colors(old_fg, old_bg);
}

// Draw a horizontal line
pub fn draw_hline(y: usize, x1: usize, x2: usize, ch: u8) void {
    if (y >= VGA_HEIGHT) return;
    
    const start_x = @min(x1, x2);
    const end_x = @max(x1, x2);
    
    var x: usize = start_x;
    while (x <= end_x and x < VGA_WIDTH) : (x += 1) {
        vga_buffer[y][x] = VGAEntry.init(ch, current_fg, current_bg);
    }
}

// Draw a vertical line
pub fn draw_vline(x: usize, y1: usize, y2: usize, ch: u8) void {
    if (x >= VGA_WIDTH) return;
    
    const start_y = @min(y1, y2);
    const end_y = @max(y1, y2);
    
    var y: usize = start_y;
    while (y <= end_y and y < VGA_HEIGHT) : (y += 1) {
        vga_buffer[y][x] = VGAEntry.init(ch, current_fg, current_bg);
    }
}

// Draw a box/frame
pub fn draw_box(x1: usize, y1: usize, x2: usize, y2: usize) void {
    // Draw corners
    if (x1 < VGA_WIDTH and y1 < VGA_HEIGHT) {
        vga_buffer[y1][x1] = VGAEntry.init('+', current_fg, current_bg);
    }
    if (x2 < VGA_WIDTH and y1 < VGA_HEIGHT) {
        vga_buffer[y1][x2] = VGAEntry.init('+', current_fg, current_bg);
    }
    if (x1 < VGA_WIDTH and y2 < VGA_HEIGHT) {
        vga_buffer[y2][x1] = VGAEntry.init('+', current_fg, current_bg);
    }
    if (x2 < VGA_WIDTH and y2 < VGA_HEIGHT) {
        vga_buffer[y2][x2] = VGAEntry.init('+', current_fg, current_bg);
    }
    
    // Draw horizontal lines
    if (y1 < VGA_HEIGHT) {
        draw_hline(y1, x1 + 1, x2 - 1, '-');
    }
    if (y2 < VGA_HEIGHT) {
        draw_hline(y2, x1 + 1, x2 - 1, '-');
    }
    
    // Draw vertical lines
    if (x1 < VGA_WIDTH) {
        draw_vline(x1, y1 + 1, y2 - 1, '|');
    }
    if (x2 < VGA_WIDTH) {
        draw_vline(x2, y1 + 1, y2 - 1, '|');
    }
}

pub fn vga_clear() void {
    var row: usize = 0;
    while (row < VGA_HEIGHT) : (row += 1) {
        var col: usize = 0;
        while (col < VGA_WIDTH) : (col += 1) {
            vga_buffer[row][col] = VGAEntry.init(' ', current_fg, current_bg);
        }
    }
    cursor_x = 0;
    cursor_y = 0;
    update_cursor();
}

// Check if VGA text mode is available
fn detect_vga_hardware() bool {
    // Try to read from the VGA buffer to see if it's accessible
    const test_value = vga_buffer[0][0];
    
    // Write a test pattern
    vga_buffer[0][0] = VGAEntry.init('A', .White, .Black);
    
    // Read it back
    const read_value = vga_buffer[0][0];
    
    // Restore original value
    vga_buffer[0][0] = test_value;
    
    // Check if our test pattern worked
    return read_value == VGAEntry.init('A', .White, .Black);
}

// Initialize VGA hardware
pub fn init() void {
    // Detect VGA hardware
    if (!detect_vga_hardware()) {
        // VGA hardware not detected, but we'll continue anyway
        // as some emulators might not respond to detection
    }
    
    // Reset CRT controller (safely)
    arch.outb(0x3D4, 0x11); // Select CRTC register 0x11
    const crt_value = arch.inb(0x3D5); // Read current value
    arch.outb(0x3D5, crt_value & 0x7F); // Clear bit 7 (protect from writes)
    
    // Clear screen
    vga_clear();
    
    // Set cursor scan lines (cursor shape)
    arch.outb(0x3D4, 0x0A); // Cursor start register
    arch.outb(0x3D5, 0x0E); // Start at scan line 14
    arch.outb(0x3D4, 0x0B); // Cursor end register
    arch.outb(0x3D5, 0x0F); // End at scan line 15
    
    // Enable cursor
    set_cursor_enabled(true);
    
    // Set default colors
    set_colors(.LightGrey, .Black);
    
    // Update cursor position
    update_cursor();
    
    // Display initialization message
    vga_write_line("VGA display initialized");
}

// Color utility functions
pub fn color_from_ansi(ansi_code: u8) Color {
    return switch (ansi_code) {
        30 => .Black,
        31 => .Red,
        32 => .Green,
        33 => .Brown,
        34 => .Blue,
        35 => .Magenta,
        36 => .Cyan,
        37 => .LightGrey,
        90 => .DarkGrey,
        91 => .LightRed,
        92 => .LightGreen,
        93 => .LightBrown,
        94 => .LightBlue,
        95 => .LightMagenta,
        96 => .LightCyan,
        97 => .White,
        else => .LightGrey,
    };
}

pub fn bg_color_from_ansi(ansi_code: u8) Color {
    return switch (ansi_code) {
        40 => .Black,
        41 => .Red,
        42 => .Green,
        43 => .Brown,
        44 => .Blue,
        45 => .Magenta,
        46 => .Cyan,
        47 => .LightGrey,
        100 => .DarkGrey,
        101 => .LightRed,
        102 => .LightGreen,
        103 => .LightBrown,
        104 => .LightBlue,
        105 => .LightMagenta,
        106 => .LightCyan,
        107 => .White,
        else => .Black,
    };
}

// Set text attributes (bold, underline, etc.)
pub fn set_bold(bold: bool) void {
    if (bold) {
        // For VGA, "bold" means using bright colors
        // We'll handle this by using light colors instead of dark ones
        if (current_fg == .Black) current_fg = .DarkGrey;
        if (current_fg == .Red) current_fg = .LightRed;
        if (current_fg == .Green) current_fg = .LightGreen;
        if (current_fg == .Brown) current_fg = .LightBrown;
        if (current_fg == .Blue) current_fg = .LightBlue;
        if (current_fg == .Magenta) current_fg = .LightMagenta;
        if (current_fg == .Cyan) current_fg = .LightCyan;
    }
}

// Reset all formatting to default
pub fn reset_formatting() void {
    set_colors(.LightGrey, .Black);
}

// Save and restore cursor position
var saved_cursor_x: usize = 0;
var saved_cursor_y: usize = 0;

pub fn save_cursor() void {
    saved_cursor_x = cursor_x;
    saved_cursor_y = cursor_y;
}

pub fn restore_cursor() void {
    move_cursor(saved_cursor_x, saved_cursor_y);
}
