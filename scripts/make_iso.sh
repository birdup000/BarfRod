#!/usr/bin/env bash
set -euo pipefail

ZIG_BIN="${TOOLCHAIN_ZIG:-./toolchain/zig/zig}"

# Build kernel ELF into zig-out/bin/barfrod
echo "[barfrod] Building kernel with Zig (${ZIG_BIN})..."
"${ZIG_BIN}" build

# Prepare ISO root
ISO_DIR="iso_root"
KERNEL_ELF="zig-out/bin/barfrod"
OUT_ISO="barfrod.iso"

mkdir -p "${ISO_DIR}/boot/grub"
mkdir -p "${ISO_DIR}/EFI/BOOT"

# Copy kernel and GRUB config
cp "${KERNEL_ELF}" "${ISO_DIR}/boot/barfrod.elf"
cp grub.cfg "${ISO_DIR}/boot/grub/grub.cfg"

# Check dependencies
check_dep() {
  if ! command -v "$1" &>/dev/null; then
    echo "Error: Required tool '$1' not found."
    echo "Please install these packages:"
    echo "  mtools dosfstools grub-pc-bin grub-efi-amd64-bin"
    echo "On Debian/Ubuntu run:"
    echo "  sudo apt-get install mtools dosfstools grub-pc-bin grub-efi-amd64-bin"
    exit 1
  fi
}

check_dep "grub-mkrescue"
check_dep "mformat"

# Create ISO with GRUB
echo "[barfrod] Creating ISO..."
grub-mkrescue -o "${OUT_ISO}" "${ISO_DIR}" || {
  echo "Error: ISO creation failed"
  echo "Common issues:"
  echo "1. Missing dependencies (see above)"
  echo "2. Need sudo permissions for some operations"
  exit 1
}
if [ -f "${OUT_ISO}" ]; then
  echo "[barfrod] ISO created: ${OUT_ISO}"
else
  echo "xorriso not found. Please install xorriso (or genisoimage + isohybrid) and rerun." >&2
  exit 1
fi

echo "[barfrod] Done."