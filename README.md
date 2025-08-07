# BarfRod — Zig-based Unix-like OS (x86_64, Limine, ISO, Serial)

BarfRod is a minimal Zig kernel scaffold, booted by Limine on x86_64. It builds a bootable ISO and runs under QEMU with serial console output.

Status
- Boot path: Limine ISO (BIOS/UEFI-capable ISO layout)
- Kernel: Zig freestanding ELF64 with custom linker script
- Console: COM1 serial (QEMU -serial stdio)
- Next steps: paging skeleton, interrupts, scheduler skeleton, VFS, ELF loader, userspace

Prerequisites
- Zig (0.12+ or master compatible)
- xorriso (mkisofs-capable) for ISO creation
- QEMU (qemu-system-x86_64)
- curl, tar, bash
- Linux host (tested)

Build and Run
- Build kernel ELF:
  - make build
  - or: zig build -Drelease-safe -Dstrip=false
- Build ISO:
  - make iso
  - or: zig build iso
- Run in QEMU:
  - make run
  - or: zig build run

You should see serial output similar to:
barfrod: entering kernel
bootloader: Limine
version   : X.Y.Z
HHDM offset hi=0x???????? lo=0x????????
Initialization complete. Halting.

Project Layout
- build.zig
- linker.ld
- limine.cfg
- src/kernel/main.zig
- scripts/make_iso.sh
- scripts/run_qemu.sh
- scripts/clean.sh
- Makefile

Notes
- Limine binaries are downloaded automatically on first ISO build into third_party/limine.
- Serial console uses COM1 at QEMU default; the run script wires -serial stdio.
- The kernel currently halts after early init; paging/interrupts are not yet enabled.

Roadmap (short)
- Early serial logging refinement and panic handler(s)
- IDT + exception stubs, PIT/HPET timebase
- Physical/virtual memory manager, higher-half mapping
- Simple allocator
- Syscall ABI sketch and userland bootstrap

License
- TBD (MIT recommended).
