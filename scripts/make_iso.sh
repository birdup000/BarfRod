#!/usr/bin/env bash
set -euo pipefail

# Build kernel ELF into zig-out/bin/barfrod
echo "[barfrod] Building kernel with Zig..."
zig build -Drelease-safe -Dstrip=false

# Prepare ISO root
ISO_DIR="iso_root"
LIMINE_DIR="third_party/limine"
KERNEL_ELF="zig-out/bin/barfrod"
OUT_ISO="barfrod.iso"

mkdir -p "${ISO_DIR}/boot"
mkdir -p "${ISO_DIR}/EFI/BOOT"
mkdir -p "${LIMINE_DIR}"

# Fetch Limine binaries if missing (v7.x branch binary release)
# We use the precompiled limine-bios.sys and limine-uefi*.efi boot files for El Torito/UEFI
if [ ! -f "${LIMINE_DIR}/limine-bios.sys" ] || [ ! -f "${LIMINE_DIR}/BOOTX64.EFI" ] || [ ! -f "${LIMINE_DIR}/limine.sys" ]; then
  echo "[barfrod] Fetching limine prebuilt (nightly) artifacts..."
  # Using official nightly tarball that includes needed files
  curl -L -o /tmp/limine.tar.gz https://github.com/limine-bootloader/limine/releases/latest/download/limine-binaries.tar.gz
  tar -xzf /tmp/limine.tar.gz -C "${LIMINE_DIR}" --strip-components=1 || true
fi

# Copy kernel and configs
cp "${KERNEL_ELF}" "${ISO_DIR}/boot/barfrod.elf"
cp limine.cfg "${ISO_DIR}/limine.cfg"

# Copy Limine boot files (both BIOS and UEFI support on ISO)
# Files may be named differently depending on tarball; support common names
copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [ -f "$src" ]; then cp "$src" "$dst"; fi
}

copy_if_exists "${LIMINE_DIR}/limine-bios.sys" "${ISO_DIR}/limine-bios.sys"
copy_if_exists "${LIMINE_DIR}/limine.sys" "${ISO_DIR}/limine.sys"
# UEFI bootloader
copy_if_exists "${LIMINE_DIR}/BOOTX64.EFI" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI"
copy_if_exists "${LIMINE_DIR}/BOOTIA32.EFI" "${ISO_DIR}/EFI/BOOT/BOOTIA32.EFI"

# Create ISO (requires xorriso or genisoimage + isohybrid)
echo "[barfrod] Creating ISO..."
if command -v xorriso &>/dev/null; then
  xorriso -as mkisofs \
    -b limine-bios.sys \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot EFI/BOOT/BOOTX64.EFI \
    -iso-level 3 -udf -J -R \
    -o "${OUT_ISO}" "${ISO_DIR}"
  echo "[barfrod] ISO created: ${OUT_ISO}"
else
  echo "xorriso not found. Please install xorriso (or genisoimage + isohybrid) and rerun." >&2
  exit 1
fi

echo "[barfrod] Done."