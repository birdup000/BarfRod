const std = @import("std");

const COM1: u16 = 0x3F8;

// Temporarily stubbed serial I/O to avoid inline asm issues on snap Zig.
// No-op implementations; restore real port I/O later.
inline fn outb(port: u16, value: u8) void {
    _ = port; _ = value;
}
inline fn inb(port: u16) u8 {
    _ = port;
    return 0;
}

fn is_transmit_empty() bool {
    return (inb(COM1 + 5) & 0x20) != 0;
}

pub fn init() void {
    outb(COM1 + 1, 0x00); // disable interrupts
    outb(COM1 + 3, 0x80); // DLAB on
    outb(COM1 + 0, 0x03); // divisor low (38400/3 = 12800 baud)
    outb(COM1 + 1, 0x00); // divisor high
    outb(COM1 + 3, 0x03); // 8N1
    outb(COM1 + 2, 0xC7); // FIFO
    outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

pub fn write_byte(b: u8) void {
    while (!is_transmit_empty()) {}
    outb(COM1, b);
}

pub fn write(s: []const u8) void {
    for (s) |ch| {
        if (ch == '\n') write_byte('\r');
        write_byte(ch);
    }
}

// Minimal hex printing helpers
pub fn write_hex(v: u64) void {
    var buf: [18]u8 = .{ '0','x','0','0','0','0','0','0','0','0','0','0','0','0','0','0','0','0' };
    var idx: usize = buf.len - 1;
    var x: u64 = v;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const nib: u4 = @intCast(@as(u4, @intCast(x & 0xF)));
        buf[idx] = "0123456789abcdef"[nib];
        x >>= 4;
        idx -= 1;
    }
    write(&buf);
}