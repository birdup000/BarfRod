# BarfRod - A Zig x86_64 Kernel

BarfRod is a modern x86_64 kernel written in Zig, featuring multiboot compliance, memory management, task scheduling, and an interactive command-line interface. Originally designed to use both Limine and GRUB bootloaders, it has been streamlined to use GRUB exclusively for maximum compatibility and reliability.

## 🚀 Features

- **Multiboot-compliant**: Boots reliably with GRUB using proper multiboot headers
- **Memory Management**: Physical memory manager and kernel heap allocator
- **Task Scheduling**: Preemptive multitasking with context switching
- **Interactive CLI**: Built-in command-line interface for kernel interaction
- **VGA Text Mode**: Basic text output for debugging and user interface
- **Serial Output**: Comprehensive serial logging for development and debugging
- **IDT Support**: Interrupt descriptor table setup and management
- **Paging**: Virtual memory management with page tables

## 🛠 Prerequisites

Before building BarfRod, ensure you have the following tools installed:

### Required Tools
- **Zig 0.14.0** (included in `toolchain/` directory)
- **GRUB utilities**: `grub-mkrescue`, `grub-pc-bin`, `grub-efi-amd64-bin`
- **ISO creation tools**: `xorriso`, `mtools`, `dosfstools`
- **QEMU**: `qemu-system-x86_64` (for testing)

### Installation (Ubuntu/Debian)
```bash
sudo apt-get update
sudo apt-get install mtools dosfstools grub-pc-bin grub-efi-amd64-bin xorriso qemu-system-x86
```

## 🏗 Building

### Quick Build
```bash
# Build kernel only
zig build

# Build kernel and create bootable ISO
zig build iso

# Build and run in QEMU
zig build run
```

### Manual Build Process
```bash
# Clean previous builds
./scripts/clean.sh

# Build kernel ELF
zig build

# Create bootable ISO with GRUB
./scripts/make_iso.sh

# Run in QEMU
./scripts/run_qemu.sh
```

## 🎮 Usage

### Running the Kernel
1. **In QEMU (Recommended for development)**:
   ```bash
   zig build run
   ```

2. **On Real Hardware**:
   - Burn the generated `barfrod.iso` to a USB drive or CD
   - Boot from the USB/CD on x86_64 hardware

### Kernel Boot Sequence
1. GRUB loads and displays boot menu
2. Kernel initializes serial communication
3. VGA text mode displays "BARF" banner
4. IDT (Interrupt Descriptor Table) initialization
5. Memory management and paging setup
6. 6-second delay for system stabilization
7. Interactive CLI becomes available

### Available CLI Commands
Once booted, the kernel provides an interactive command-line interface with various debugging and system commands.

## 🏛 Architecture

### Project Structure
```
BarfRod/
├── src/kernel/          # Kernel source code
│   ├── main.zig        # Entry point and boot logic
│   ├── vga.zig         # VGA text mode driver
│   ├── serial.zig      # Serial communication
│   ├── idt.zig         # Interrupt handling
│   ├── paging.zig      # Virtual memory management
│   ├── pmm.zig         # Physical memory manager
│   ├── kheap.zig       # Kernel heap allocator
│   ├── scheduler.zig   # Task scheduler
│   ├── context.zig     # Context switching
│   ├── task.zig        # Task management
│   └── cli.zig         # Command-line interface
├── scripts/             # Build and utility scripts
├── toolchain/           # Zig compiler toolchain
├── grub.cfg            # GRUB configuration
├── linker.ld           # Custom linker script
└── build.zig           # Zig build configuration
```

### Key Components

- **Multiboot Header**: Properly aligned 4-byte multiboot header in `.multiboot` section
- **Memory Management**: Physical and virtual memory managers with heap allocation
- **Task System**: Preemptive multitasking with round-robin scheduling
- **I/O Systems**: VGA text output and serial communication for debugging
- **Boot Protocol**: GRUB-compatible multiboot implementation

## 🐛 Troubleshooting

### Common Issues

1. **"No multiboot header found" error**:
   - This was a known issue with Zig release mode optimization
   - **Fixed**: Proper multiboot header alignment and linker script ordering
   - The kernel now boots reliably in both debug and release modes

2. **ISO creation fails**:
   - Ensure all GRUB tools are installed: `grub-mkrescue`, `xorriso`
   - Check that you have write permissions in the project directory

3. **QEMU doesn't start**:
   - Verify `qemu-system-x86_64` is installed and in PATH
   - Check that the ISO file exists: `ls -la barfrod.iso`

### Debug Information

The kernel provides extensive serial logging. To capture debug output:
- Serial output is available on `stdio` when running in QEMU
- Physical hardware: Connect to COM1 (115200 baud, 8N1)
- Debug log file: `debug.log` (when using QEMU debugcon)

## 🔧 Development

### Modifying the Kernel

1. **Adding new features**: Create new `.zig` files in `src/kernel/`
2. **Updating build**: Modify `build.zig` for new dependencies
3. **Testing changes**: Use `zig build run` for quick testing
4. **Memory debugging**: Check serial output for allocation/deallocation info

### Release Notes

**Latest Version**: GRUB-Only Release
- ✅ Removed Limine bootloader dependency
- ✅ Fixed multiboot header alignment issues
- ✅ Streamlined build process for GRUB-only usage
- ✅ Improved boot reliability across different systems
- ✅ Enhanced serial debugging output

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes and test thoroughly
4. Ensure the kernel builds and boots: `zig build run`
5. Submit a pull request with a clear description

### Code Style
- Follow Zig naming conventions
- Use meaningful variable names
- Include comments for complex algorithms
- Test changes in both debug and release modes

## 📜 License

This project is released under the MIT License. See the LICENSE file for details.

## 🙏 Acknowledgments

- **Zig Language Team**: For creating an excellent systems programming language
- **GRUB Project**: For the reliable multiboot bootloader implementation
- **OSDev Community**: For extensive documentation and support
- **QEMU Project**: For providing excellent emulation for kernel development

---

**Happy kernel hacking!** 🚀

For questions, issues, or contributions, please open an issue on the project repository.
