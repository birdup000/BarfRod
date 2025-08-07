const std = @import("std");
const serial = @import("serial.zig");

// Very early Physical Memory Manager (PMM) using a simple bitmap.
// Assumptions for bootstrap:
//  - We only allocate pages from a fixed early pool [phys_start .. phys_start + size)
//  - Page size = 4 KiB
//  - We do not yet parse Limine memory map; that will come next iteration.
//  - Provides kalloc_page/kfree_page primitives for paging/kheap bootstrap.

pub const PAGE_SIZE: usize = 4096;

// Static early pool: 16 MiB starting at 16 MiB (to avoid low memory/bootloader areas)
// In a proper PMM, we will fill this from Limine memory map and avoid reserved regions.
const EARLY_POOL_BASE: usize = 16 * 1024 * 1024; // 16 MiB
const EARLY_POOL_SIZE: usize = 16 * 1024 * 1024; // 16 MiB
const EARLY_PAGE_COUNT: usize = EARLY_POOL_SIZE / PAGE_SIZE;

// Bitmap: 1 bit per page; 0 = free, 1 = used
var bitmap: [EARLY_PAGE_COUNT / 8]u8 = [_]u8{0} ** (EARLY_PAGE_COUNT / 8);

// Simple spinlock placeholder (single-core early bring-up, no-op)
fn lock() void {}
fn unlock() void {}

// Helpers to get/set bits
inline fn bit_is_set(idx: usize) bool {
    return (bitmap[idx / 8] >> @intCast(@as(u3, @intCast(idx & 7)))) & 1 == 1;
}
inline fn set_bit(idx: usize) void {
    bitmap[idx / 8] |= @as(u8, 1) << @intCast(@as(u3, @intCast(idx & 7)));
}
inline fn clear_bit(idx: usize) void {
    bitmap[idx / 8] &= ~(@as(u8, 1) << @intCast(@as(u3, @intCast(idx & 7))));
}

inline fn phys_from_index(idx: usize) usize {
    return EARLY_POOL_BASE + idx * PAGE_SIZE;
}
inline fn index_from_phys(phys: usize) usize {
    return (phys - EARLY_POOL_BASE) / PAGE_SIZE;
}

// Reserve a range [start, end) by page index
fn reserve_range(start_idx: usize, page_count: usize) void {
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        set_bit(start_idx + i);
    }
}

// Public API

pub fn init() void {
    // Mark everything free initially
    @memset(&bitmap, 0);

    // Reserve first few pages of the pool if needed (none strictly necessary for our fixed base),
    // but keep the first page of the pool reserved to catch null-ish usage.
    if (EARLY_PAGE_COUNT > 0) set_bit(0);

    serial.write("pmm: early pool at phys 0x");
    serial.write_hex(@intCast(@as(u64, EARLY_POOL_BASE)));
    serial.write(" size=");
    serial.write_hex(@intCast(@as(u64, EARLY_POOL_SIZE)));
    serial.write(" bytes, pages=");
    serial.write_hex(@intCast(@as(u64, EARLY_PAGE_COUNT)));
    serial.write("\n");
}

// Allocate one physical 4KiB page, returns physical address or 0 on failure.
pub fn alloc_page() usize {
    lock();
    defer unlock();

    var idx: usize = 0;
    while (idx < EARLY_PAGE_COUNT) : (idx += 1) {
        if (!bit_is_set(idx)) {
            set_bit(idx);
            const phys = phys_from_index(idx);
            // Zeroing a physical page would require mapping; defer for now.
            return phys;
        }
    }
    return 0;
}

// Free one physical page at address 'phys' that must be 4KiB-aligned and within the pool.
pub fn free_page(phys: usize) void {
    if (phys < EARLY_POOL_BASE) return;
    if ((phys - EARLY_POOL_BASE) >= EARLY_POOL_SIZE) return;
    if ((phys & (PAGE_SIZE - 1)) != 0) return;

    lock();
    defer unlock();

    const idx = index_from_phys(phys);
    clear_bit(idx);
}

// Allocate 'n' contiguous pages (best-effort, first-fit). Returns phys addr or 0.
pub fn alloc_pages(n: usize) usize {
    if (n == 0) return 0;

    lock();
    defer unlock();

    var run_len: usize = 0;
    var run_start: usize = 0;

    var idx: usize = 0;
    while (idx < EARLY_PAGE_COUNT) : (idx += 1) {
        if (!bit_is_set(idx)) {
            if (run_len == 0) run_start = idx;
            run_len += 1;
            if (run_len == n) {
                var j: usize = 0;
                while (j < n) : (j += 1) set_bit(run_start + j);
                return phys_from_index(run_start);
            }
        } else {
            run_len = 0;
        }
    }
    return 0;
}

pub fn free_pages(phys: usize, n: usize) void {
    if (n == 0) return;
    if (phys < EARLY_POOL_BASE) return;
    if ((phys - EARLY_POOL_BASE) >= EARLY_POOL_SIZE) return;
    if ((phys & (PAGE_SIZE - 1)) != 0) return;

    lock();
    defer unlock();

    const start = index_from_phys(phys);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        clear_bit(start + i);
    }
}