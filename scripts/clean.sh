#!/usr/bin/env bash
set -euo pipefail
echo "[barfrod] Cleaning artifacts..."
rm -rf zig-out barfrod.iso iso_root debug.log
echo "[barfrod] Done."