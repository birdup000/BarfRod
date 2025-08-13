// Architecture-specific definitions and utilities for x86_64

const std = @import("std");
const interrupts = @import("interrupts.zig");

// CPU registers structure for context switching
pub const Registers = extern struct {
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
    vector: u64,    // Interrupt vector
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// CPU control registers
pub const CR0 = packed struct {
    pub const PE = 1 << 0;   // Protection Enable
    pub const MP = 1 << 1;   // Monitor Coprocessor
    pub const EM = 1 << 2;   // Emulation
    pub const TS = 1 << 3;   // Task Switched
    pub const ET = 1 << 4;   // Extension Type
    pub const NE = 1 << 5;   // Numeric Error
    pub const WP = 1 << 16;  // Write Protect
    pub const AM = 1 << 18;  // Alignment Mask
    pub const NW = 1 << 29;  // Not Write-through
    pub const CD = 1 << 30;  // Cache Disable
    pub const NWCD = 1 << 31;  // Not Write-through and Cache Disable
};

pub const CR4 = packed struct {
    pub const VME = 1 << 0;   // Virtual-8086 Mode Extensions
    pub const PVI = 1 << 1;   // Protected-Mode Virtual Interrupts
    pub const TSD = 1 << 2;   // Time Stamp Disable
    pub const DE = 1 << 3;    // Debugging Extensions
    pub const PSE = 1 << 4;   // Page Size Extension
    pub const PAE = 1 << 5;   // Physical Address Extension
    pub const MCE = 1 << 6;   // Machine Check Enable
    pub const PGE = 1 << 7;   // Page Global Enable
    pub const PCE = 1 << 8;   // Performance-Monitoring Counter Enable
    pub const OSFXSR = 1 << 9;  // Operating System FXSAVE/FXRSTOR Support
    pub const OSXMMEXCPT = 1 << 10; // Operating System Unmasked Exception Support
    pub const UMIP = 1 << 11; // User-Mode Instruction Prevention
    pub const LA57 = 1 << 12; // 5-Level Paging
    pub const VMXE = 1 << 13; // VMX Enable
    pub const SMXE = 1 << 14; // SMX Enable
    pub const FSGSBASE = 1 << 16; // FSGSBASE Instructions Enable
    pub const PCIDE = 1 << 17; // PCID Enable
    pub const OSXSAVE = 1 << 18; // XSAVE and Processor Extended States Enable
    pub const SMEP = 1 << 20; // Supervisor-Mode Execution Prevention
    pub const SMAP = 1 << 21; // Supervisor-Mode Access Prevention
    pub const PKE = 1 << 22;  // Protection Key Enable
    pub const CET = 1 << 23;  // Control-flow Enforcement Technology
    pub const PKS = 1 << 24;  // Protection Key for Supervisor Pages
};

// EFER register
pub const EFER = packed struct {
    pub const SCE = 1 << 0;   // SYSCALL Enable
    pub const LME = 1 << 8;   // Long Mode Enable
    pub const LMA = 1 << 10;  // Long Mode Active
    pub const NXE = 1 << 11;  // No-Execute Enable
    pub const SVME = 1 << 12; // Secure Virtual Machine Enable
    pub const LMSLE = 1 << 13; // Long Mode Segment Limit Enable
    pub const FFXSR = 1 << 14; // Fast FXSAVE/FXRSTOR
    pub const TCE = 1 << 15;  // Translation Cache Extension
};

// Page table entry flags
pub const PTE = packed struct {
    pub const P = 1 << 0;     // Present
    pub const W = 1 << 1;     // Writable
    pub const U = 1 << 2;     // User
    pub const WT = 1 << 3;    // Write-Through
    pub const CD = 1 << 4;    // Cache-Disable
    pub const A = 1 << 5;     // Accessed
    pub const D = 1 << 6;     // Dirty
    pub const PS = 1 << 7;    // Page Size
    pub const G = 1 << 8;     // Global
    pub const PAT = 1 << 7;   // Page Attribute Table (in PTE only)
    pub const XD = 1 << 63;   // Execute Disable
};

// Memory layout
pub const MEMORY_LAYOUT = struct {
    pub const KERNEL_BASE: u64 = 0x00100000; // 1MB
    pub const KERNEL_OFFSET: u64 = 0x00100000; // 1MB
    pub const KERNEL_PHYS_BASE: u64 = 0x00100000;
    pub const KERNEL_VIRT_BASE: u64 = 0x00100000;
    pub const KERNEL_STACK_SIZE: u64 = 0x10000; // 64KB
    pub const USER_STACK_TOP: u64 = 0x00007FFFFFFFF000;
    pub const USER_STACK_SIZE: u64 = 0x10000; // 64KB
    pub const PAGE_SIZE: u64 = 0x1000; // 4KB
    pub const HUGE_PAGE_SIZE: u64 = 0x200000; // 2MB
    
    // Hardware addresses mapped in kernel space
    pub const VGA_BUFFER_VIRT: u64 = 0xB8000;
    pub const VGA_CTRL_REGS_VIRT: u64 = 0x3D4;
    pub const SERIAL_PORT_VIRT: u64 = 0x3F8;
};

// Page size constant for direct access
pub const PAGE_SIZE: u64 = 0x1000; // 4KB

// RFLAGS register constants
pub const RFLAGS = struct {
    pub const CF: u64 = 1 << 0;     // Carry Flag
    pub const PF: u64 = 1 << 2;     // Parity Flag
    pub const AF: u64 = 1 << 4;     // Auxiliary Carry Flag
    pub const ZF: u64 = 1 << 6;     // Zero Flag
    pub const SF: u64 = 1 << 7;     // Sign Flag
    pub const TF: u64 = 1 << 8;     // Trap Flag
    pub const IF: u64 = 1 << 9;     // Interrupt Enable Flag
    pub const DF: u64 = 1 << 10;    // Direction Flag
    pub const OF: u64 = 1 << 11;    // Overflow Flag
    pub const NT: u64 = 1 << 14;    // Nested Task Flag
    pub const RF: u64 = 1 << 16;    // Resume Flag
    pub const VM: u64 = 1 << 17;    // Virtual Mode
    pub const AC: u64 = 1 << 18;    // Alignment Check
    pub const VIF: u64 = 1 << 19;   // Virtual Interrupt Flag
    pub const VIP: u64 = 1 << 20;   // Virtual Interrupt Pending
    pub const ID: u64 = 1 << 21;    // CPUID Detection Flag
};

// CPU features detection
pub const CpuFeatures = struct {
    fxsr: bool,
    sse: bool,
    sse2: bool,
    sse3: bool,
    ssse3: bool,
    sse4_1: bool,
    sse4_2: bool,
    avx: bool,
    avx2: bool,
    xsave: bool,
    xsaveopt: bool,
    osxsave: bool,
    fsgsbase: bool,
    smep: bool,
    smap: bool,
    nx: bool,
    pge: bool,
    pae: bool,
    pat: bool,
    pse: bool,
    syscall: bool,
    tsc: bool,
    mtrr: bool,
    mce: bool,
    cmov: bool,
    clflush: bool,
    mmx: bool,
    pclmulqdq: bool,
    dtes64: bool,
    monitor: bool,
    ds_cpl: bool,
    vmx: bool,
    smx: bool,
    eist: bool,
    tm2: bool,
    cnxt_id: bool,
    sdbg: bool,
    fma: bool,
    cx16: bool,
    xtpr: bool,
    pdcm: bool,
    pcid: bool,
    dca: bool,
    x2apic: bool,
    movbe: bool,
    popcnt: bool,
    tsc_deadline: bool,
    aes: bool,
    f16c: bool,
    rdrand: bool,
    fpu: bool,
    vme: bool,
    de: bool,
    msr: bool,
    cx8: bool,
    apic: bool,
    sep: bool,
    mca: bool,
    pse_36: bool,
    psn: bool,
    ds: bool,
    acpi: bool,
    ss: bool,
    htt: bool,
    tm: bool,
    pbe: bool,
    tsc_adjust: bool,
    bmi1: bool,
    hle: bool,
    bmi2: bool,
    erms: bool,
    invpcid: bool,
    rtm: bool,
    mpx: bool,
    adx: bool,
    sha: bool,
};

// GDT entries
pub const GDTEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    flags_limit_high: u8,
    base_high: u8,
};

// TSS structure
pub const TSS = extern struct {
    reserved1: u32,
    rsp0: u64,   // Kernel stack pointer
    rsp1: u64,   // IST stack pointer 1
    rsp2: u64,   // IST stack pointer 2
    reserved2: u64,
    ist1: u64,   // IST 1
    ist2: u64,   // IST 2
    ist3: u64,   // IST 3
    ist4: u64,   // IST 4
    ist5: u64,   // IST 5
    ist6: u64,   // IST 6
    ist7: u64,   // IST 7
    reserved3: u64,
    reserved4: u16,
    iopb_offset: u16,
};

// Architecture-specific functions
pub fn read_cr0() u64 {
    return asm volatile ("mov %%cr0, %[result]"
        : [result] "=r" (-> u64)
    );
}

pub fn write_cr0(value: u64) void {
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (value)
    );
}

pub fn read_cr2() u64 {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> u64)
    );
}

pub fn read_cr3() u64 {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64)
    );
}

pub fn write_cr3(value: u64) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (value)
    );
}

pub fn read_cr4() u64 {
    return asm volatile ("mov %%cr4, %[result]"
        : [result] "=r" (-> u64)
    );
}

pub fn write_cr4(value: u64) void {
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "r" (value)
    );
}

pub fn read_msr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high)
        : [msr] "{ecx}" (msr)
    );
    return (@as(u64, high) << 32) | low;
}

pub fn write_msr(msr: u32, value: u64) void {
    const low = @as(u32, @truncate(value));
    const high = @as(u32, @truncate(value >> 32));
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high)
    );
}

pub fn read_rflags() u64 {
    return asm volatile ("pushfq; popq %[result]"
        : [result] "=r" (-> u64)
    );
}

pub fn write_rflags(value: u64) void {
    asm volatile ("pushq %[value]; popfq"
        :
        : [value] "r" (value)
    );
}

pub fn enable_interrupts() void {
    asm volatile ("sti");
}

pub fn disable_interrupts() void {
    asm volatile ("cli");
}

pub fn halt() void {
    asm volatile ("hlt");
}

pub fn pause() void {
    asm volatile ("pause");
}

pub fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr)
        : "memory"
    );
}

pub fn cpuid(eax_param: u32, ecx_param: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    var eax_result: u32 = undefined;
    var ebx_result: u32 = undefined;
    var ecx_result: u32 = undefined;
    var edx_result: u32 = undefined;
    
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax_result),
          [ebx] "={ebx}" (ebx_result),
          [ecx] "={ecx}" (ecx_result),
          [edx] "={edx}" (edx_result)
        : [eax_param] "{eax}" (eax_param),
          [ecx_param] "{ecx}" (ecx_param)
    );
    
    return .{
        .eax = eax_result,
        .ebx = ebx_result,
        .ecx = ecx_result,
        .edx = edx_result,
    };
}

pub fn port_in_u8(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8)
        : [port] "{dx}" (port)
    );
}

pub fn port_out_u8(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port)
    );
}

pub fn port_in_u16(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16)
        : [port] "{dx}" (port)
    );
}

pub fn port_out_u16(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port)
    );
}

pub fn port_in_u32(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32)
        : [port] "{dx}" (port)
    );
}

pub fn port_out_u32(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port)
    );
}

// Port I/O convenience functions
pub fn inb(port: u16) u8 {
    return port_in_u8(port);
}

pub fn outb(port: u16, value: u8) void {
    port_out_u8(port, value);
}

pub fn inl(port: u16) u32 {
    return port_in_u32(port);
}

pub fn outl(port: u16, value: u32) void {
    port_out_u32(port, value);
}

pub fn read_rbp() u64 {
    return asm volatile ("mov %%rbp, %[result]"
        : [result] "=r" (-> u64)
    );
}

// Get CPU features
pub fn get_cpu_features() CpuFeatures {
    const max_leaf = cpuid(0, 0).eax;
    
    var features = CpuFeatures{
        .fxsr = false,
        .sse = false,
        .sse2 = false,
        .sse3 = false,
        .ssse3 = false,
        .sse4_1 = false,
        .sse4_2 = false,
        .avx = false,
        .avx2 = false,
        .xsave = false,
        .xsaveopt = false,
        .osxsave = false,
        .fsgsbase = false,
        .smep = false,
        .smap = false,
        .nx = false,
        .pge = false,
        .pae = false,
        .pat = false,
        .pse = false,
        .syscall = false,
        .tsc = false,
        .mtrr = false,
        .mce = false,
        .cmov = false,
        .clflush = false,
        .mmx = false,
        .pclmulqdq = false,
        .dtes64 = false,
        .monitor = false,
        .ds_cpl = false,
        .vmx = false,
        .smx = false,
        .eist = false,
        .tm2 = false,
        .cnxt_id = false,
        .sdbg = false,
        .fma = false,
        .cx16 = false,
        .xtpr = false,
        .pdcm = false,
        .pcid = false,
        .dca = false,
        .x2apic = false,
        .movbe = false,
        .popcnt = false,
        .tsc_deadline = false,
        .aes = false,
        .f16c = false,
        .rdrand = false,
        .fpu = false,
        .vme = false,
        .de = false,
        .msr = false,
        .cx8 = false,
        .apic = false,
        .sep = false,
        .mca = false,
        .pse_36 = false,
        .psn = false,
        .ds = false,
        .acpi = false,
        .ss = false,
        .htt = false,
        .tm = false,
        .pbe = false,
        .tsc_adjust = false,
        .bmi1 = false,
        .hle = false,
        .bmi2 = false,
        .erms = false,
        .invpcid = false,
        .rtm = false,
        .mpx = false,
        .adx = false,
        .sha = false,
    };
    
    if (max_leaf >= 1) {
        const result1 = cpuid(1, 0);
        features.sse3 = (result1.ecx & (1 << 0)) != 0;
        features.pclmulqdq = (result1.ecx & (1 << 1)) != 0;
        features.dtes64 = (result1.ecx & (1 << 2)) != 0;
        features.monitor = (result1.ecx & (1 << 3)) != 0;
        features.ds_cpl = (result1.ecx & (1 << 4)) != 0;
        features.vmx = (result1.ecx & (1 << 5)) != 0;
        features.smx = (result1.ecx & (1 << 6)) != 0;
        features.eist = (result1.ecx & (1 << 7)) != 0;
        features.tm2 = (result1.ecx & (1 << 8)) != 0;
        features.ssse3 = (result1.ecx & (1 << 9)) != 0;
        features.cnxt_id = (result1.ecx & (1 << 10)) != 0;
        features.sdbg = (result1.ecx & (1 << 11)) != 0;
        features.fma = (result1.ecx & (1 << 12)) != 0;
        features.cx16 = (result1.ecx & (1 << 13)) != 0;
        features.xtpr = (result1.ecx & (1 << 14)) != 0;
        features.pdcm = (result1.ecx & (1 << 15)) != 0;
        features.pcid = (result1.ecx & (1 << 17)) != 0;
        features.dca = (result1.ecx & (1 << 18)) != 0;
        features.sse4_1 = (result1.ecx & (1 << 19)) != 0;
        features.sse4_2 = (result1.ecx & (1 << 20)) != 0;
        features.x2apic = (result1.ecx & (1 << 21)) != 0;
        features.movbe = (result1.ecx & (1 << 22)) != 0;
        features.popcnt = (result1.ecx & (1 << 23)) != 0;
        features.tsc_deadline = (result1.ecx & (1 << 24)) != 0;
        features.aes = (result1.ecx & (1 << 25)) != 0;
        features.xsave = (result1.ecx & (1 << 26)) != 0;
        features.osxsave = (result1.ecx & (1 << 27)) != 0;
        features.avx = (result1.ecx & (1 << 28)) != 0;
        features.f16c = (result1.ecx & (1 << 29)) != 0;
        features.rdrand = (result1.ecx & (1 << 30)) != 0;
        
        features.fpu = (result1.edx & (1 << 0)) != 0;
        features.vme = (result1.edx & (1 << 1)) != 0;
        features.de = (result1.edx & (1 << 2)) != 0;
        features.pse = (result1.edx & (1 << 3)) != 0;
        features.tsc = (result1.edx & (1 << 4)) != 0;
        features.msr = (result1.edx & (1 << 5)) != 0;
        features.pae = (result1.edx & (1 << 6)) != 0;
        features.mce = (result1.edx & (1 << 7)) != 0;
        features.cx8 = (result1.edx & (1 << 8)) != 0;
        features.apic = (result1.edx & (1 << 9)) != 0;
        features.sep = (result1.edx & (1 << 11)) != 0;
        features.mtrr = (result1.edx & (1 << 12)) != 0;
        features.pge = (result1.edx & (1 << 13)) != 0;
        features.mca = (result1.edx & (1 << 14)) != 0;
        features.cmov = (result1.edx & (1 << 15)) != 0;
        features.pat = (result1.edx & (1 << 16)) != 0;
        features.pse_36 = (result1.edx & (1 << 17)) != 0;
        features.psn = (result1.edx & (1 << 18)) != 0;
        features.clflush = (result1.edx & (1 << 19)) != 0;
        features.ds = (result1.edx & (1 << 21)) != 0;
        features.acpi = (result1.edx & (1 << 22)) != 0;
        features.mmx = (result1.edx & (1 << 23)) != 0;
        features.fxsr = (result1.edx & (1 << 24)) != 0;
        features.sse = (result1.edx & (1 << 25)) != 0;
        features.sse2 = (result1.edx & (1 << 26)) != 0;
        features.ss = (result1.edx & (1 << 27)) != 0;
        features.htt = (result1.edx & (1 << 28)) != 0;
        features.tm = (result1.edx & (1 << 29)) != 0;
        features.pbe = (result1.edx & (1 << 31)) != 0;
    }
    
    if (max_leaf >= 7) {
        const result7 = cpuid(7, 0);
        features.fsgsbase = (result7.ebx & (1 << 0)) != 0;
        features.tsc_adjust = (result7.ebx & (1 << 1)) != 0;
        features.bmi1 = (result7.ebx & (1 << 3)) != 0;
        features.hle = (result7.ebx & (1 << 4)) != 0;
        features.avx2 = (result7.ebx & (1 << 5)) != 0;
        features.smep = (result7.ebx & (1 << 7)) != 0;
        features.bmi2 = (result7.ebx & (1 << 8)) != 0;
        features.erms = (result7.ebx & (1 << 9)) != 0;
        features.invpcid = (result7.ebx & (1 << 10)) != 0;
        features.rtm = (result7.ebx & (1 << 11)) != 0;
        features.mpx = (result7.ebx & (1 << 14)) != 0;
        features.smap = (result7.ebx & (1 << 20)) != 0;
        features.adx = (result7.ebx & (1 << 19)) != 0;
        features.sha = (result7.ebx & (1 << 29)) != 0;
    }
    
    if (max_leaf >= 0x80000001) {
        const result80000001 = cpuid(0x80000001, 0);
        features.nx = (result80000001.edx & (1 << 20)) != 0;
        features.syscall = (result80000001.edx & (1 << 11)) != 0;
    }
    
    return features;
}

// Global tick counter
var tick_count: u64 = 0;

// Get current tick count
pub fn get_ticks() u64 {
    return tick_count;
}

// PIT timer interrupt handler
fn timer_handler() void {
    tick_count += 1;
}

// Initialize PIT (Programmable Interval Timer)
pub fn init_pit() void {
    // Configure PIT to 1000 Hz (1193182 / 1193 ≈ 1000)
    outb(0x43, 0x36);
    outb(0x40, 0xA9); // Low byte
    outb(0x40, 0x04); // High byte

    // Register timer interrupt handler
    interrupts.register_irq_handler(0, timer_handler);
}