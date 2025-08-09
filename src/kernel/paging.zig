const std = @import("std");
const serial = @import("serial.zig");

// Top-level paging API expected by main.zig:
//   pub fn setup_paging(kernel_phys_base: u64) *[512]u64
//   pub fn load_cr3(pml4_phys: u64) void
//   pub fn enable_paging_flags() void
//
// This file defines plain top-level pub fns so that `const paging = @import("paging.zig");`
// provides paging.setup_paging / paging.load_cr3 / paging.enable_paging_flags.

pub const PAGE_SIZE: usize = 4096;
pub const KERNEL_VMA: usize = 0xFFFF_FFFF_8000_0000;

const PTE_P: u64 = 1 << 0;   // present
const PTE_W: u64 = 1 << 1;   // writable
const PTE_U: u64 = 1 << 2;   // user (unused here)
const PTE_PWT: u64 = 1 << 3; // write-through
const PTE_PCD: u64 = 1 << 4; // cache-disable
const PTE_A: u64 = 1 << 5;   // accessed
const PTE_D: u64 = 1 << 6;   // dirty
const PTE_PS: u64 = 1 << 7;  // page size (1=2MiB/1GiB)
const PTE_G: u64 = 1 << 8;   // global
const PTE_NX: u64 = 1 << 63; // no-execute

pub const Tables = extern struct {
    pml4: [512]u64 align(4096),
    pdpt: [512]u64 align(4096),
    pd:   [512]u64 align(4096),
};

// Statically allocate early tables
pub export var boot_tables: Tables align(4096) = .{
    .pml4 = [_]u64{0} ** 512,
    .pdpt = [_]u64{0} ** 512,
    .pd   = [_]u64{0} ** 512,
};

inline fn make_entry(addr: u64, flags: u64) u64 {
    return (addr & 0x000f_ffff_ffff_f000) | flags;
}

fn map_identity_1GiB(pd: *[512]u64) void {
    // Map first 1 GiB using 2MiB pages (512 entries)
    var i: usize = 0;
    var phys: u64 = 0;
    while (i < 512) : (i += 1) {
        pd[i] = make_entry(phys, PTE_P | PTE_W | PTE_PS | PTE_G);
        phys += 2 * 1024 * 1024;
    }
}

fn index_pml4(vaddr: usize) usize { return (vaddr >> 39) & 0x1FF; }
fn index_pdpt(vaddr: usize) usize { return (vaddr >> 30) & 0x1FF; }

pub fn setup_paging(kernel_phys_base: u64) *[512]u64 {
    _ = kernel_phys_base;

    @memset(&boot_tables.pml4, 0);
    @memset(&boot_tables.pdpt, 0);
    @memset(&boot_tables.pd, 0);

    // Identity map 0..1GiB
    map_identity_1GiB(&boot_tables.pd);

    const pdpt_phys: u64 = @as(u64, @intFromPtr(&boot_tables.pdpt));
    const pd_phys: u64   = @as(u64, @intFromPtr(&boot_tables.pd));

    // PML4[0] -> PDPT, PDPT[0] -> PD (identity)
    boot_tables.pml4[0] = make_entry(pdpt_phys, PTE_P | PTE_W);
    boot_tables.pdpt[0] = make_entry(pd_phys,   PTE_P | PTE_W);

    // Higher-half mirror for kernel
    const pml4_hh = index_pml4(KERNEL_VMA);
    const pdpt_hh = index_pdpt(KERNEL_VMA);
    boot_tables.pml4[pml4_hh] = make_entry(pdpt_phys, PTE_P | PTE_W);
    boot_tables.pdpt[pdpt_hh] = make_entry(pd_phys,   PTE_P | PTE_W);

    serial.write("paging: pml4_hh=");
    serial.write_hex(@intCast(@as(u64, pml4_hh)));
    serial.write(" pdpt_hh=");
    serial.write_hex(@intCast(@as(u64, pdpt_hh)));
    serial.write("\n");

    return &boot_tables.pml4;
}

pub fn load_cr3(pml4_phys: u64) void {
    asm volatile ("mov %[pml4], %%cr3"
        :
        : [pml4] "r" (pml4_phys)
        : "memory"
    );
}

pub fn enable_paging_flags() void {
    // Enable paging (PG bit) and protection (PE bit) in CR0
    asm volatile (
        \\mov %%cr0, %%rax
        \\or $0x80000001, %%eax
        \\mov %%rax, %%cr0
        :
        :
        : "rax", "memory"
    );
}