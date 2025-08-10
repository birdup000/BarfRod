const std = @import("std");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

// VGA text mode functions (imported from vga.zig)
const VGA_WIDTH = vga.VGA_WIDTH;
const VGA_HEIGHT = vga.VGA_HEIGHT;
const vga_buffer = vga.vga_buffer;
const VGA_COLOR = vga.VGA_COLOR;

fn vga_write_byte(ch: u8) void {
    vga.vga_write_byte(ch);
}

fn vga_write(s: []const u8) void {
    vga.vga_write(s);
}

fn vga_clear() void {
    vga.vga_clear();
}


const MAX_COMMAND_LENGTH = 256;
const MAX_ARGS = 16;

pub const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn (args: [][]const u8) void,
};

// Built-in commands
fn cmd_help(args: [][]const u8) void {
    _ = args;
    vga.vga_write("Available commands:\n");
    vga.vga_write("  help     - Show this help message\n");
    vga.vga_write("  clear    - Clear the screen\n");
    vga.vga_write("  echo     - Echo text to the screen\n");
    vga.vga_write("  exit     - Exit the CLI (halt system)\n");
    vga.vga_write("  version  - Show kernel version\n");
}

fn cmd_clear(args: [][]const u8) void {
    _ = args;
    vga.vga_clear();
}

fn cmd_echo(args: [][]const u8) void {
    if (args.len == 0) {
        vga.vga_write("\n");
        return;
    }
    
    for (args, 0..) |arg, i| {
        vga.vga_write(arg);
        if (i < args.len - 1) {
            vga.vga_write(" ");
        }
    }
    vga.vga_write("\n");
}

fn cmd_exit(args: [][]const u8) void {
    _ = args;
    vga.vga_write("Shutting down...\n");
    // Halt the system
    asm volatile ("cli; hlt");
}

fn cmd_version(args: [][]const u8) void {
    _ = args;
    vga.vga_write("BarfRod Kernel v0.1\n");
}

// Command table
const COMMANDS = [_]Command{
    Command{
        .name = "help",
        .description = "Show help message",
        .handler = cmd_help,
    },
    Command{
        .name = "clear",
        .description = "Clear screen",
        .handler = cmd_clear,
    },
    Command{
        .name = "echo",
        .description = "Echo text",
        .handler = cmd_echo,
    },
    Command{
        .name = "exit",
        .description = "Exit CLI",
        .handler = cmd_exit,
    },
    Command{
        .name = "version",
        .description = "Show version",
        .handler = cmd_version,
    },
};

fn parse_command(line: []const u8, args: [][]const u8) usize {
    var arg_count: usize = 0;
    var i: usize = 0;
    
    while (i < line.len and arg_count < args.len) {
        // Skip leading whitespace
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
            i += 1;
        }
        if (i >= line.len) break;
        
        const start = i;
        
        // Parse argument (simple version - no quotes)
        while (i < line.len and line[i] != ' ' and line[i] != '\t') {
            i += 1;
        }
        
        if (i > start) {
            args[arg_count] = line[start..i];
            arg_count += 1;
        }
    }
    
    return arg_count;
}

pub fn execute_command(cmd_line: []const u8) void {
    if (cmd_line.len == 0) return;
    
    // Parse command and arguments
    var args_storage: [MAX_ARGS][]const u8 = undefined;
    const arg_count = parse_command(cmd_line, args_storage[0..]);
    
    if (arg_count == 0) return;
    
    const cmd_name = args_storage[0];
    const args = args_storage[1..arg_count];
    
    // Find and execute command
    for (COMMANDS) |cmd| {
        if (std.mem.eql(u8, cmd.name, cmd_name)) {
            cmd.handler(@ptrCast(args));
            return;
        }
    }
    
    // Command not found
    serial.write("Command '");
    serial.write(cmd_name);
    serial.write("' not found. Type 'help' for available commands.\n");
}

pub fn run_cli() void {
    vga.vga_write("BarfRod Interactive CLI\n");
    vga.vga_write("Type 'help' for available commands.\n\n");
    
    while (true) {
        vga.vga_write("barfrod> ");
        
        // Read from serial with polling to avoid blocking
        var line_buffer: [MAX_COMMAND_LENGTH]u8 = undefined;
        var i: usize = 0;
        
        while (i < MAX_COMMAND_LENGTH - 1) {
            // Check if data is available before reading
            if (serial.is_data_available()) {
                const ch = serial.read_byte();
                if (ch == '\r' or ch == '\n') {
                    break;
                }
                line_buffer[i] = ch;
                i += 1;
                // Echo character to VGA as we type
                vga.vga_write_byte(ch);
            } else {
                // Small delay to prevent busy waiting
                var delay: u32 = 0;
                while (delay < 1000) : (delay += 1) {
                    asm volatile ("nop");
                }
            }
        }
        
        line_buffer[i] = 0; // null terminate
        
        if (i > 0) {
            vga.vga_write_byte('\n');
            const cmd_line = line_buffer[0..i];
            execute_command(cmd_line);
        } else {
            vga.vga_write_byte('\n');
        }
    }
}