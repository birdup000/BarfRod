// Advanced Interrupt Descriptor Table (IDT) and interrupt handling system
const std = @import("std");
const arch = @import("arch.zig");
const serial = @import("serial.zig");
const process = @import("process.zig");
const vmm = @import("vmm.zig");

// Interrupt vectors
pub const InterruptVector = enum(u8) {
    // Exceptions (0-31)
    DivideByZero = 0,
    Debug = 1,
    NonMaskableInterrupt = 2,
    Breakpoint = 3,
    Overflow = 4,
    BoundRangeExceeded = 5,
    InvalidOpcode = 6,
    DeviceNotAvailable = 7,
    DoubleFault = 8,
    InvalidTSS = 10,
    SegmentNotPresent = 11,
    StackSegmentFault = 12,
    GeneralProtection = 13,
    PageFault = 14,
    x87FPUError = 16,
    AlignmentCheck = 17,
    MachineCheck = 18,
    SIMDFloatingPoint = 19,
    Virtualization = 20,
    Security = 30,
    
    // IRQs (32-47)
    Timer = 32,
    Keyboard = 33,
    Cascade = 34,
    COM2 = 35,
    COM1 = 36,
    LPT2 = 37,
    Floppy = 38,
    LPT1 = 39,
    RTC = 40,
    Mouse = 44,
    FPU = 47,
    
    // Syscall (128)
    Syscall = 128,
    
    // Software interrupts (200-255)
    UserInterrupt1 = 200,
    UserInterrupt2 = 201,
    UserInterrupt3 = 202,
};

// Interrupt gate types
pub const GateType = enum(u8) {
    InterruptGate = 0xE,
    TrapGate = 0xF,
};

// IDT entry structure
pub const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_middle: u16,
    offset_high: u32,
    reserved: u32,
    
    pub fn init(offset: u64, selector: u16, ist: u8, gate_type: GateType, dpl: u8) IDTEntry {
        const type_attr = @as(u8, @intCast((1 << 7) | (dpl << 5) | @intFromEnum(gate_type)));
        return .{
            .offset_low = @as(u16, @truncate(offset & 0xFFFF)),
            .selector = selector,
            .ist = ist,
            .type_attr = type_attr,
            .offset_middle = @as(u16, @truncate((offset >> 16) & 0xFFFF)),
            .offset_high = @as(u32, @truncate((offset >> 32) & 0xFFFFFFFF)),
            .reserved = 0,
        };
    }
};

// IDT structure
pub const IDT = extern struct {
    entries: [256]IDTEntry,
    
    pub fn init() IDT {
        var new_idt: IDT = undefined;
        for (&new_idt.entries) |*entry| {
            entry.* = IDTEntry.init(0, 0, 0, .InterruptGate, 0);
        }
        return new_idt;
    }
    
    pub fn set_gate(self: *IDT, vector: u8, offset: u64, selector: u16, ist: u8, gate_type: GateType, dpl: u8) void {
        self.entries[vector] = IDTEntry.init(offset, selector, ist, gate_type, dpl);
    }
};

// IDT register structure
pub const IDTR = packed struct {
    limit: u16,
    base: u64,
};

// Interrupt context
pub const InterruptContext = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// Interrupt handler function type
pub const InterruptHandler = *const fn (context: *InterruptContext) void;

// Interrupt handler table
var interrupt_handlers: [256]?InterruptHandler = [_]?InterruptHandler{null} ** 256;

// Exception names for debugging
const exception_names = [32][]const u8{
    "Divide By Zero",
    "Debug",
    "Non-Maskable Interrupt",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Reserved",
    "Invalid TSS",
    "Segment Not Present",
    "Stack Segment Fault",
    "General Protection",
    "Page Fault",
    "Reserved",
    "x87 FPU Error",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating Point",
    "Virtualization",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Security",
    "Reserved",
};

// Global IDT instance
var idt: IDT = undefined;

// Initialize IDT
pub fn init() void {
    idt = IDT.init();
    
    // Set up exception handlers
    set_exception_handler(@intFromEnum(InterruptVector.DivideByZero), handle_divide_by_zero);
    set_exception_handler(@intFromEnum(InterruptVector.Debug), handle_debug);
    set_exception_handler(@intFromEnum(InterruptVector.NonMaskableInterrupt), handle_nmi);
    set_exception_handler(@intFromEnum(InterruptVector.Breakpoint), handle_breakpoint);
    set_exception_handler(@intFromEnum(InterruptVector.Overflow), handle_overflow);
    set_exception_handler(@intFromEnum(InterruptVector.BoundRangeExceeded), handle_bound_range);
    set_exception_handler(@intFromEnum(InterruptVector.InvalidOpcode), handle_invalid_opcode);
    set_exception_handler(@intFromEnum(InterruptVector.DeviceNotAvailable), handle_device_not_available);
    set_exception_handler(@intFromEnum(InterruptVector.DoubleFault), handle_double_fault);
    set_exception_handler(@intFromEnum(InterruptVector.InvalidTSS), handle_invalid_tss);
    set_exception_handler(@intFromEnum(InterruptVector.SegmentNotPresent), handle_segment_not_present);
    set_exception_handler(@intFromEnum(InterruptVector.StackSegmentFault), handle_stack_fault);
    set_exception_handler(@intFromEnum(InterruptVector.GeneralProtection), handle_general_protection);
    set_exception_handler(@intFromEnum(InterruptVector.PageFault), handle_page_fault);
    set_exception_handler(@intFromEnum(InterruptVector.x87FPUError), handle_x87_fpu_error);
    set_exception_handler(@intFromEnum(InterruptVector.AlignmentCheck), handle_alignment_check);
    set_exception_handler(@intFromEnum(InterruptVector.MachineCheck), handle_machine_check);
    set_exception_handler(@intFromEnum(InterruptVector.SIMDFloatingPoint), handle_simd_floating_point);
    set_exception_handler(@intFromEnum(InterruptVector.Virtualization), handle_virtualization);
    set_exception_handler(@intFromEnum(InterruptVector.Security), handle_security);
    
    // Set up IRQ handlers
    set_interrupt_handler(@intFromEnum(InterruptVector.Timer), handle_timer);
    set_interrupt_handler(@intFromEnum(InterruptVector.Keyboard), handle_keyboard);
    set_interrupt_handler(@intFromEnum(InterruptVector.COM1), handle_serial);
    set_interrupt_handler(@intFromEnum(InterruptVector.RTC), handle_rtc);
    
    // Set up syscall handler
    set_syscall_handler(@intFromEnum(InterruptVector.Syscall), handle_syscall);
    
    // Load IDT
    load_idt();
    
    serial.write("interrupts: IDT initialized\n");
}

// Set exception handler
fn set_exception_handler(vector: u8, handler: InterruptHandler) void {
    const offset = @intFromPtr(&exception_wrapper);
    idt.set_gate(vector, offset, 0x08, 0, .InterruptGate, 0);
    interrupt_handlers[vector] = handler;
}

// Set interrupt handler
fn set_interrupt_handler(vector: u8, handler: InterruptHandler) void {
    const offset = @intFromPtr(&interrupt_wrapper);
    idt.set_gate(vector, offset, 0x08, 0, .InterruptGate, 0);
    interrupt_handlers[vector] = handler;
}

// Set syscall handler
fn set_syscall_handler(vector: u8, handler: InterruptHandler) void {
    const offset = @intFromPtr(&syscall_wrapper);
    idt.set_gate(vector, offset, 0x08, 0, .TrapGate, 3); // DPL=3 for user access
    interrupt_handlers[vector] = handler;
}

// Load IDT
fn load_idt() void {
    const idtr = IDTR{
        .limit = @sizeOf(IDT) - 1,
        .base = @intFromPtr(&idt),
    };
    
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr)
        : "memory"
    );
}

// Exception handlers
fn handle_divide_by_zero(__context: *InterruptContext) void {
    serial.write("Exception: Divide By Zero\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_debug(__context: *InterruptContext) void {
    serial.write("Exception: Debug\n");
    // dump_registers(context);
    _ = __context;
}

fn handle_nmi(__context: *InterruptContext) void {
    serial.write("Exception: Non-Maskable Interrupt\n");
    // dump_registers(context);
    _ = __context;
}

fn handle_breakpoint(__context: *InterruptContext) void {
    serial.write("Exception: Breakpoint\n");
    // dump_registers(context);
    _ = __context;
}

fn handle_overflow(__context: *InterruptContext) void {
    serial.write("Exception: Overflow\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_bound_range(__context: *InterruptContext) void {
    serial.write("Exception: Bound Range Exceeded\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_invalid_opcode(__context: *InterruptContext) void {
    serial.write("Exception: Invalid Opcode\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_device_not_available(__context: *InterruptContext) void {
    serial.write("Exception: Device Not Available\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_double_fault(__context: *InterruptContext) void {
    serial.write("Exception: Double Fault\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_invalid_tss(__context: *InterruptContext) void {
    serial.write("Exception: Invalid TSS\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_segment_not_present(__context: *InterruptContext) void {
    serial.write("Exception: Segment Not Present\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_stack_fault(__context: *InterruptContext) void {
    serial.write("Exception: Stack Segment Fault\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_general_protection(__context: *InterruptContext) void {
    serial.write("Exception: General Protection Fault\n");
    // serial.write("Error code: 0x");
    // serial.write_hex(context.error_code);
    // serial.write("\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_page_fault(__context: *InterruptContext) void {
    const fault_addr = arch.read_cr2();
    serial.write("Exception: Page Fault\n");
    serial.write("Faulting address: 0x");
    serial.write_hex(fault_addr);
    serial.write("\n");
    // serial.write("Error code: 0x");
    // serial.write_hex(context.error_code);
    // serial.write("\n");
    
    // Try to handle page fault through VMM
    vmm.handle_page_fault(fault_addr, 0);
    
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_x87_fpu_error(__context: *InterruptContext) void {
    serial.write("Exception: x87 FPU Error\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_alignment_check(__context: *InterruptContext) void {
    serial.write("Exception: Alignment Check\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_machine_check(__context: *InterruptContext) void {
    serial.write("Exception: Machine Check\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_simd_floating_point(__context: *InterruptContext) void {
    serial.write("Exception: SIMD Floating Point\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_virtualization(__context: *InterruptContext) void {
    serial.write("Exception: Virtualization\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

fn handle_security(__context: *InterruptContext) void {
    serial.write("Exception: Security\n");
    // dump_registers(context);
    _ = __context;
    while (true) arch.halt();
}

// Interrupt handlers
fn handle_timer(__context: *InterruptContext) void {
    // Send EOI to PIC
    outb(0x20, 0x20);
    
    // Call timer interrupt handler
    process.timer_interrupt();
    _ = __context;
}

fn handle_keyboard(__context: *InterruptContext) void {
    // Read scan code
    // const scan_code = inb(0x60);
    // _ = scan_code;
    
    // Process keyboard input
    // TODO: Implement keyboard driver
    
    // Send EOI to PIC
    outb(0x20, 0x20);
    _ = __context;
}

fn handle_serial(__context: *InterruptContext) void {
    // Handle serial interrupt
    // TODO: Implement serial driver
    
    // Send EOI to PIC
    outb(0x20, 0x20);
    _ = __context;
}

fn handle_rtc(__context: *InterruptContext) void {
    // Handle RTC interrupt
    // TODO: Implement RTC driver
    
    // Send EOI to PIC
    outb(0x20, 0x20);
    _ = __context;
}

fn handle_syscall(__context: *InterruptContext) void {
    // Call syscall handler
    // We need to create a Registers struct from the InterruptContext
    var regs = arch.Registers{
        .r15 = __context.r15,
        .r14 = __context.r14,
        .r13 = __context.r13,
        .r12 = __context.r12,
        .r11 = __context.r11,
        .r10 = __context.r10,
        .r9 = __context.r9,
        .r8 = __context.r8,
        .rbp = __context.rbp,
        .rdi = __context.rdi,
        .rsi = __context.rsi,
        .rdx = __context.rdx,
        .rcx = __context.rcx,
        .rbx = __context.rbx,
        .rax = __context.rax,
        .vector = __context.vector,
        .error_code = __context.error_code,
        .rip = __context.rip,
        .cs = __context.cs,
        .rflags = __context.rflags,
        .rsp = __context.rsp,
        .ss = __context.ss,
    };
    process.syscall_handler(&regs);
}

// Common interrupt handler
pub fn handle_interrupt(vector: u8, _context: *InterruptContext) void {
    if (interrupt_handlers[vector]) |handler| {
        handler(_context);
    } else {
        serial.write("Unhandled interrupt: ");
        serial.write_hex(@as(u64, vector));
        serial.write("\n");
        // dump_registers(_context);
    }
}

// Dump registers for debugging
fn dump_registers(__context: *InterruptContext) void {
    serial.write("Registers:\n");
    // serial.write("  RAX: 0x"); serial.write_hex(context.rax); serial.write("\n");
    // serial.write("  RBX: 0x"); serial.write_hex(context.rbx); serial.write("\n");
    // serial.write("  RCX: 0x"); serial.write_hex(context.rcx); serial.write("\n");
    // serial.write("  RDX: 0x"); serial.write_hex(context.rdx); serial.write("\n");
    // serial.write("  RSI: 0x"); serial.write_hex(context.rsi); serial.write("\n");
    // serial.write("  RDI: 0x"); serial.write_hex(context.rdi); serial.write("\n");
    // serial.write("  RBP: 0x"); serial.write_hex(context.rbp); serial.write("\n");
    // serial.write("  RSP: 0x"); serial.write_hex(context.rsp); serial.write("\n");
    // serial.write("  R8:  0x"); serial.write_hex(context.r8);  serial.write("\n");
    // serial.write("  R9:  0x"); serial.write_hex(context.r9);  serial.write("\n");
    // serial.write("  R10: 0x"); serial.write_hex(context.r10); serial.write("\n");
    // serial.write("  R11: 0x"); serial.write_hex(context.r11); serial.write("\n");
    // serial.write("  R12: 0x"); serial.write_hex(context.r12); serial.write("\n");
    // serial.write("  R13: 0x"); serial.write_hex(context.r13); serial.write("\n");
    // serial.write("  R14: 0x"); serial.write_hex(context.r14); serial.write("\n");
    // serial.write("  R15: 0x"); serial.write_hex(context.r15); serial.write("\n");
    // serial.write("  RIP: 0x"); serial.write_hex(context.rip); serial.write("\n");
    // serial.write("  RFLAGS: 0x"); serial.write_hex(context.rflags); serial.write("\n");
    // serial.write("  CS: 0x"); serial.write_hex(context.cs); serial.write("\n");
    // serial.write("  SS: 0x"); serial.write_hex(context.ss); serial.write("\n");
    _ = __context;
}

// I/O port functions
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port)
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8)
        : [port] "{dx}" (port)
    );
}

// Assembly wrappers
extern fn exception_wrapper() void;
extern fn interrupt_wrapper() void;
extern fn syscall_wrapper() void;

// Initialize PIC (Programmable Interrupt Controller)
pub fn init_pic() void {
    // ICW1: Initialize PIC in cascade mode
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    
    // ICW2: Set vector offset
    outb(0x21, 0x20); // IRQ0-7 mapped to 0x20-0x27
    outb(0xA1, 0x28); // IRQ8-15 mapped to 0x28-0x2F
    
    // ICW3: Set cascade identity
    outb(0x21, 0x04); // PIC1 has slave on IRQ2
    outb(0xA1, 0x02); // PIC2 is slave on PIC1's IRQ2
    
    // ICW4: Set 8086 mode
    outb(0x21, 0x01);
    outb(0xA1, 0x01);
    
    // Mask all interrupts
    outb(0x21, 0xFF);
    outb(0xA1, 0xFF);
    
    serial.write("interrupts: PIC initialized\n");
}

// Enable IRQ
pub fn enable_irq(irq: u8) void {
    const port: u16 = if (irq < 8) 0x21 else 0xA1;
    const irq_bit: u3 = @truncate(if (irq < 8) irq else irq - 8);
    const mask = inb(port);
    outb(port, mask & ~(@as(u8, 1) << irq_bit));
}

// Disable IRQ
pub fn disable_irq(irq: u8) void {
    const port = if (irq < 8) 0x21 else 0xA1;
    const irq_bit: u3 = @truncate(if (irq < 8) irq else irq - 8);
    const mask = inb(port);
    outb(port, mask | (@as(u8, 1) << irq_bit));
}

// Enable interrupts
pub fn enable_interrupts() void {
    arch.enable_interrupts();
}

// Disable interrupts
pub fn disable_interrupts() void {
    arch.disable_interrupts();
}

pub fn save_flags() u64 {
    return arch.read_rflags();
}

pub fn restore_flags(flags: u64) void {
    if (flags & arch.RFLAGS.IF != 0) {
        arch.enable_interrupts();
    } else {
        arch.disable_interrupts();
    }
}