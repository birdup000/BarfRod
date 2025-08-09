const std = @import("std");
const serial = @import("serial.zig");

 // Minimal IDT with basic exception stubs for x86_64 long mode.
 // Note: Avoid runtime calls or serial writes from naked handlers on this toolchain.
 // Inline asm is also restricted; we will wire proper .S stubs later.
pub const Gate = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,          // 3 bits IST, 5 bits zero
    type_attr: u8,    // type and attributes
    offset_mid: u16,
    offset_high: u32,
    zero: u32,
};

pub const IDT = extern struct {
    gates: [256]Gate,
};

pub const Idtr = packed struct {
    limit: u16,
    base: u64,
};

// Initialize with zeroed gates (there is no Gate.zero method; use default literal)
pub export var idt: IDT = .{ .gates = [_]Gate{ .{ .offset_low = 0, .selector = 0, .ist = 0, .type_attr = 0, .offset_mid = 0, .offset_high = 0, .zero = 0 } } ** 256 };

pub inline fn handler_to_gate(h: *const fn () callconv(.Naked) void, ist_index: u3, is_trap: bool) Gate {
    const addr = @intFromPtr(h);
    const typ: u8 = if (is_trap) 0xF else 0xE; // trap=0xF, interrupt=0xE
    const attr: u8 = (1 << 7) | (0 << 5) | (1 << 4) | typ; // P | DPL=0 | 0 | type
    return Gate{
        .offset_low = @intCast(@as(u16, @intCast(addr & 0xFFFF))),
        .selector = 0x08, // kernel code segment (assumes GDT set by bootloader; Limine sets a flat GDT)
        .ist = @as(u8, ist_index & 0x7),
        .type_attr = attr,
        .offset_mid = @intCast(@as(u16, @intCast((addr >> 16) & 0xFFFF))),
        .offset_high = @intCast(@as(u32, @intCast((addr >> 32) & 0xFFFF_FFFF))),
        .zero = 0,
    };
}

pub fn set_gate(vec: u8, gate: Gate) void {
    idt.gates[vec] = gate;
}

fn lidt(base: *const IDT) void {
    const idtr = Idtr{
        .limit = @sizeOf(IDT) - 1,
        .base = @intFromPtr(base),
    };
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr)
        : "memory"
    );
}

// Naked handlers: preserve minimal state and jump to a common stub that logs then halts.
// For real kernels, you'd push error codes properly, save registers, etc.

fn gen_naked_noerr(comptime vec: u8) fn () callconv(.Naked) void {
    return struct {
        fn h() callconv(.Naked) void {
            asm volatile (
                \\pushq $0
                \\pushq %[vector]
                \\jmp isr_common_stub
                :
                : [vector] "i" (vec)
            );
        }
    }.h;
}

pub fn init() void {
    // zero
    var i: usize = 0;
    while (i < idt.gates.len) : (i += 1) {
        idt.gates[i] = .{ .offset_low = 0, .selector = 0, .ist = 0, .type_attr = 0, .offset_mid = 0, .offset_high = 0, .zero = 0 };
    }

    // Setup a few common exception vectors (no-error) using interrupt gates
    set_gate(0, handler_to_gate(gen_naked_noerr(0), 0, false));   // #DE
    set_gate(1, handler_to_gate(gen_naked_noerr(1), 0, false));   // #DB
    set_gate(3, handler_to_gate(gen_naked_noerr(3), 0, false));   // #BP
    set_gate(6, handler_to_gate(gen_naked_noerr(6), 0, false));   // #UD
    set_gate(13, handler_to_gate(gen_naked_noerr(13), 0, false)); // #GP
    set_gate(14, handler_to_gate(gen_naked_noerr(14), 0, false)); // #PF

    // Load the IDT
    lidt(&idt);
    serial.write("idt: loaded\n");
}

// Assembly stub for common ISR handling
export fn isr_common_stub() callconv(.Naked) noreturn {
    asm volatile (
        \\cli
        \\hlt
        \\jmp isr_common_stub
    );
}