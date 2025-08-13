const std = @import("std");
const vga = @import("vga.zig");
const arch = @import("arch.zig");
const serial = @import("serial.zig");

// CLI state
pub const CLI = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    history: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CLI {
        return .{
            .history = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CLI) void {
        for (self.history.items) |cmd| {
            self.allocator.free(cmd);
        }
        self.history.deinit();
    }

    pub fn clear_buffer(self: *CLI) void {
        self.len = 0;
    }

    pub fn add_char(self: *CLI, ch: u8) void {
        if (self.len < self.buffer.len - 1) {
            self.buffer[self.len] = ch;
            self.len += 1;
            vga.vga_write_byte(ch);
        }
    }

    pub fn backspace(self: *CLI) void {
        if (self.len > 0) {
            self.len -= 1;
            vga.vga_write_byte(8); // Backspace
            vga.vga_write_byte(' ');
            vga.vga_write_byte(8);
        }
    }

    pub fn execute(self: *CLI) void {
        const cmd = self.buffer[0..self.len];
        if (cmd.len == 0) return;

        // Add to history
        const cmd_copy = self.allocator.dupe(u8, cmd) catch return;
        self.history.append(cmd_copy) catch {};

        // Process command
        vga.vga_write_byte('\n');
        if (std.mem.eql(u8, cmd, "help")) {
            vga.vga_write_line("Available commands: help, clear, echo, meminfo");
        } else if (std.mem.eql(u8, cmd, "clear")) {
            vga.vga_clear();
        } else if (std.mem.startsWith(u8, cmd, "echo ")) {
            vga.vga_write_line(cmd[5..]);
        } else if (std.mem.eql(u8, cmd, "meminfo")) {
            // TODO: Add memory info command
            vga.vga_write_line("Memory info not implemented yet");
        } else {
            vga.vga_write("Unknown command: ");
            vga.vga_write_line(cmd);
        }

        self.clear_buffer();
        self.show_prompt();
    }

    pub fn show_prompt(_: *CLI) void {
        vga.vga_write_colored("> ", .LightGreen, .Black);
    }
};

// Handle keyboard input for CLI
pub fn handle_key_event(self: *CLI, key: u8) void {
    // Explicitly use key parameter to avoid compiler warning
    const k = key;
    switch (k) {
        13 => self.execute(), // Enter
        8 => self.backspace(), // Backspace
        27 => {}, // Escape
        else => {
            if (k >= 32 and k <= 126) { // Printable ASCII
                self.add_char(k);
            }
        },
    }
}