#!/usr/bin/env bash
set -euo pipefail

ISO="barfrod.iso"
ZIG_BIN="${TOOLCHAIN_ZIG:-./toolchain/zig/zig}"

if [ ! -f "${ISO}" ]; then
  echo "[barfrod] ISO not found. Building ISO first with ${ZIG_BIN}..."
  TOOLCHAIN_ZIG="${ZIG_BIN}" bash scripts/make_iso.sh
fi

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_ARGS=(
  -machine type=q35,accel=tcg
  -m 256M
  -cpu qemu64
  -serial stdio
  -debugcon file:debug.log -global isa-debugcon.iobase=0x402
  -no-reboot
  -cdrom "${ISO}"
  -boot d
  -display sdl
  -vga std
)

echo "[barfrod] Running QEMU..."
exec "${QEMU_BIN}" "${QEMU_ARGS[@]}"