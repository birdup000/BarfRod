const std = @import("std");

// VGA text mode constants
pub const VGA_WIDTH = 80;
pub const VGA_HEIGHT = 25;
pub const vga_buffer = @as(*volatile [VGA_HEIGHT][VGA_WIDTH]u16, @ptrFromInt(0xB8000));
pub const VGA_COLOR: u16 = 0x0F00; // White text on black background

// Global cursor variables
pub var cursor_x: usize = 0;
pub var cursor_y: usize = 0;

pub fn vga_write_byte(ch: u8) void {
    if (ch == '\n') {
        cursor_x = 0;
        cursor_y += 1;
        if (cursor_y >= VGA_HEIGHT) {
            // Scroll screen up
            var row: usize = 0;
            while (row < VGA_HEIGHT - 1) : (row += 1) {
                var col: usize = 0;
                while (col < VGA_WIDTH) : (col += 1) {
                    vga_buffer[row][col] = vga_buffer[row + 1][col];
                }
            }
            // Clear last line
            var col: usize = 0;
            while (col < VGA_WIDTH) : (col += 1) {
                vga_buffer[VGA_HEIGHT - 1][col] = VGA_COLOR | @as(u16, ' ');
            }
            cursor_y = VGA_HEIGHT - 1;
        }
    } else if (ch == '\r') {
        cursor_x = 0;
    } else {
        if (cursor_x >= VGA_WIDTH) {
            cursor_x = 0;
            cursor_y += 1;
        }
        if (cursor_y >= VGA_HEIGHT) {
            // Scroll screen up
            var row: usize = 0;
            while (row < VGA_HEIGHT - 1) : (row += 1) {
                var col: usize = 0;
                while (col < VGA_WIDTH) : (col += 1) {
                    vga_buffer[row][col] = vga_buffer[row + 1][col];
                }
            }
            // Clear last line
            var col: usize = 0;
            while (col < VGA_WIDTH) : (col += 1) {
                vga_buffer[VGA_HEIGHT - 1][col] = VGA_COLOR | @as(u16, ' ');
            }
            cursor_y = VGA_HEIGHT - 1;
        }
        vga_buffer[cursor_y][cursor_x] = VGA_COLOR | @as(u16, ch);
        cursor_x += 1;
    }
}

pub fn vga_write(s: []const u8) void {
    for (s) |ch| {
        vga_write_byte(ch);
    }
}

pub fn vga_clear() void {
    var row: usize = 0;
    while (row < VGA_HEIGHT) : (row += 1) {
        var col: usize = 0;
        while (col < VGA_WIDTH) : (col += 1) {
            vga_buffer[row][col] = VGA_COLOR | ' ';
        }
    }
    cursor_x = 0;
    cursor_y = 0;
}
