const std = @import("std");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");

// Very early kernel heap:
//  - Phase 1: simple bump allocator on top of contiguous physical pages mapped
//             1:1 by early paging (sufficient for bootstrap, drivers init).
//  - Phase 2: a tiny free-list for coarse frees (same-size blocks not guaranteed).
//
// NOTE: This early heap assumes identity mapping for low memory and that
//       allocations are page-aligned multiples for simplicity. We relax that by
//       carving sub-blocks from a virtually contiguous region grown by pages.

pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;

// Configuration
const INITIAL_HEAP_PAGES: usize = 16; // 64 KiB
const GROW_PAGES: usize = 16;         // grow by 64 KiB chunks

// Heap state
var heap_start: usize = 0; // virtual address
var heap_end: usize = 0;   // current committed end
var heap_cap: usize = 0;   // reserved end (end of last grown chunk)

const BlockHeader = extern struct {
    size: usize,    // size of block payload (not including header)
    next: ?*BlockHeader,
};

var free_list: ?*BlockHeader = null;
var init_done: bool = false;

pub fn init() void {
    if (init_done) return;
    // Bootstrap: reserve INITIAL_HEAP_PAGES*PAGE_SIZE bytes by backing with pages from PMM.
    const bytes = INITIAL_HEAP_PAGES * PAGE_SIZE;
    const phys = pmm.alloc_pages(INITIAL_HEAP_PAGES);
    if (phys == 0) {
        serial.write("kheap: failed to reserve initial pages\n");
        return;
    }

    // Early paging identity maps low memory; use phys as virt for now.
    heap_start = phys;
    heap_end = heap_start;
    heap_cap = heap_start + bytes;

    // Entire region is initially one large free block.
    const hdr_ptr = @as([*]u8, @ptrFromInt(heap_start));
    const hdr = @as(*BlockHeader, @alignCast(@ptrCast(hdr_ptr)));
    hdr.* = .{ .size = bytes - @sizeOf(BlockHeader), .next = null };
    free_list = hdr;

    init_done = true;
    serial.write("kheap: init start=0x");
    serial.write_hex(@intCast(@as(u64, heap_start)));
    serial.write(" size=0x");
    serial.write_hex(@intCast(@as(u64, bytes)));
    serial.write("\n");
}

fn grow_heap(min_extra: usize) bool {
    var grow_bytes = GROW_PAGES * PAGE_SIZE;
    if (grow_bytes < min_extra) {
        // round up to page multiple covering min_extra
        const pages = (min_extra + PAGE_SIZE - 1) / PAGE_SIZE;
        grow_bytes = pages * PAGE_SIZE;
    }

    const pages = grow_bytes / PAGE_SIZE;
    const phys = pmm.alloc_pages(pages);
    if (phys == 0) return false;

    // Identity mapping assumed for now.
    if (heap_cap == 0) {
        heap_start = phys;
        heap_end = phys;
        heap_cap = phys + grow_bytes;
    } else {
        // If newly allocated range is not contiguous with current cap,
        // we still form a separate free block linked into free_list.
        // For simplicity we just link it; a real heap would require VM mapping.
        if (phys + grow_bytes == heap_cap) {
            heap_cap += grow_bytes;
        }
    }

    // Add the new region as a free block
    const hptr = @as([*]u8, @ptrFromInt(phys));
    const hdr = @as(*BlockHeader, @ptrCast(hptr));
    hdr.* = .{ .size = grow_bytes - @sizeOf(BlockHeader), .next = free_list };
    free_list = hdr;

    return true;
}

fn align_up(v: usize, a: usize) usize {
    return (v + (a - 1)) & ~(a - 1);
}

fn split_block(prev: ?*BlockHeader, blk: *BlockHeader, needed: usize) void {
    // If enough room to split, create a new header for the remainder.
    const total_size = blk.size;
    if (total_size >= needed + @sizeOf(BlockHeader) + 16) {
        const payload_ptr = @intFromPtr(blk) + @sizeOf(BlockHeader);
        const new_payload = payload_ptr + needed;
        const new_hdr_ptr = align_up(new_payload, @alignOf(BlockHeader)) - @sizeOf(BlockHeader);
        if (new_hdr_ptr + @sizeOf(BlockHeader) <= @intFromPtr(blk) + @sizeOf(BlockHeader) + total_size) {
            const nhptr = @as([*]u8, @ptrFromInt(new_hdr_ptr));
            const new_hdr = @as(*BlockHeader, @ptrCast(nhptr));
            new_hdr.* = .{
                .size = (@intFromPtr(blk) + @sizeOf(BlockHeader) + total_size) - (new_hdr_ptr + @sizeOf(BlockHeader)),
                .next = blk.next,
            };
            blk.size = needed;
            blk.next = new_hdr;
        }
    }
    // Unlink blk from free list
    if (prev) |p| {
        p.next = blk.next;
    } else {
        free_list = blk.next;
    }
}

pub fn alloc(bytes: usize, alignment: usize) ?*anyopaque {
    if (!init_done) init();

    const a = if (alignment == 0) @alignOf(usize) else alignment;
    const needed = align_up(bytes, @max(a, @alignOf(BlockHeader)));

    var prev: ?*BlockHeader = null;
    var cur = free_list;
    while (cur) |blk| {
        const blk_payload = @intFromPtr(blk) + @sizeOf(BlockHeader);
        const aligned_payload = align_up(blk_payload, a);
        const align_overhead = aligned_payload - blk_payload;
        if (align_overhead <= blk.size and blk.size - align_overhead >= needed) {
            // If alignment forces us to skip some bytes, we can split a tiny header at front.
            if (align_overhead >= @sizeOf(BlockHeader) + 16) {
                // Create a tiny header for the front fragment
                // front_hdr unused; remove to silence warning
                const front_payload_end = blk_payload + align_overhead;
                const rest_hdr_ptr = front_payload_end - @sizeOf(BlockHeader);
                const rhptr = @as([*]u8, @ptrFromInt(rest_hdr_ptr));
                const rest_hdr = @as(*BlockHeader, @ptrCast(rhptr));
                rest_hdr.* = .{
                    .size = blk.size - align_overhead,
                    .next = blk.next,
                };
                // Fix previous link to point to the remainder (rest_hdr)
                if (prev) |p| {
                    p.next = rest_hdr;
                } else {
                    free_list = rest_hdr;
                }
                // Use rest_hdr as blk
                cur = rest_hdr;
            }

            // Now 'cur' points to a block aligned correctly or align overhead treated.
            split_block(prev, blk, needed);
            const user_ptr = @as(*anyopaque, @ptrFromInt(@intFromPtr(blk) + @sizeOf(BlockHeader)));
            return user_ptr;
        }
        prev = blk;
        cur = blk.next;
    }

    // Need to grow and retry
    if (!grow_heap(needed + 2 * PAGE_SIZE)) return null;
    return alloc(bytes, alignment);
}

pub fn free(ptr: *anyopaque, size: usize) void {
    if (ptr == null) return;
    const hdr_ptr = @intFromPtr(ptr) - @sizeOf(BlockHeader);
    const hptr2 = @as([*]u8, @ptrFromInt(hdr_ptr));
    const hdr = @as(*BlockHeader, @ptrCast(hptr2));
    hdr.size = size;

    // Push to free list (no coalescing in this minimal version)
    hdr.next = free_list;
    free_list = hdr;
}

pub fn calloc(n: usize, elem_size: usize, alignment: usize) ?*anyopaque {
    const total = n * elem_size;
    const p = alloc(total, alignment) orelse return null;
    // We assume identity mapping; zeroing is safe.
    const bytes: [*]u8 = @as([*]u8, @ptrCast(p.?));
    var i: usize = 0;
    while (i < total) : (i += 1) bytes[i] = 0;
    return p;
}