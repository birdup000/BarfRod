@echo off
REM Windows batch script to run BarfRod kernel in QEMU

echo Build BarfRod Kernel...
zig build

REM Check if QEMU is available
where qemu-system-x86_64 >nul 2>&1
if %errorlevel% neq 0 (
    echo QEMU not found. Please install QEMU and add it to PATH.
    echo For Windows: https://www.qemu.org/download/#windows
    pause
    exit /b 1
)

REM Create ISO manually using Windows commands
echo Creating ISO image...

REM Create ISO structure
mkdir -p iso_root\boot\grub 2>nul
copy zig-out\bin\barfrod  iso_root\boot\barfrod.elf 2>nul
copy grub.cfg        iso_root\boot\grub\grub.cfg 2>nul

echo Running kernel in QEMU...
qemu-system-x86_64 ^
    -machine type=q35,accel=tcg ^
    -m 256M ^
    -cpu qemu64 ^
    -serial stdio ^
    -debugcon file:debug.log -global isa-debugcon.iobase=0x402 ^
    -no-reboot ^
    -kernel zig-out\bin\barfrod ^
    -display sdl ^
    -vga std

pause
