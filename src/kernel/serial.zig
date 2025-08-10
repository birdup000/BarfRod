const std = @import("std");
const kheap = @import("kheap.zig");

const COM1: u16 = 0x3F8;

// Real serial I/O using inline assembly
inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port)
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8)
        : [port] "{dx}" (port)
    );
}

fn is_transmit_empty() bool {
    return (inb(COM1 + 5) & 0x20) != 0;
}

// Check if data is available to read
pub fn is_data_available() bool {
    return (inb(COM1 + 5) & 0x01) != 0;
}

// Read a byte from serial port
pub fn read_byte() u8 {
    while (!is_data_available()) {
        // Wait for data to be available
    }
    return inb(COM1);
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

// Read a line from serial input (null-terminated string)
pub fn read_line(buffer: []u8) usize {
    var i: usize = 0;
    while (i < buffer.len - 1) {
        const ch = read_byte();
        if (ch == '\r' or ch == '\n') {
            break;
        }
        buffer[i] = ch;
        i += 1;
    }
    buffer[i] = 0; // null terminate
    return i;
}

// Simple test function to verify serial is working
pub fn test_serial() void {
    write("Serial test: OK\n");
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