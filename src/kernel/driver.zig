// Driver framework for the redesigned kernel
const std = @import("std");
const arch = @import("arch.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const process = @import("process.zig");
const interrupts = @import("interrupts.zig");
const syscall = @import("syscall.zig");
const spinlock = @import("spinlock.zig");
const kheap = @import("kheap.zig");
const fs = @import("fs.zig");

// Driver types
pub const DriverType = enum {
    Character,
    Block,
    Network,
    Bus,
    Input,
    Display,
    Sound,
    Other,
};

// Driver flags
pub const DriverFlags = packed struct {
    initialized: bool = false,
    running: bool = false,
    removable: bool = false,
    hotpluggable: bool = false,
    _padding: u4 = 0,
};

// Device types
pub const DeviceType = enum {
    PCI,
    USB,
    ISA,
    PNP,
    Platform,
    Virtual,
    Other,
};

// Device status
pub const DeviceStatus = enum {
    Unknown,
    Present,
    Enabled,
    Disabled,
    Error,
    Removed,
};

// Device operations
pub const DeviceOperations = struct {
    probe: ?*const fn (*Device) anyerror!bool = null,
    init: ?*const fn (*Device) anyerror!void = null,
    deinit: ?*const fn (*Device) anyerror!void = null,
    suspend_device: ?*const fn (*Device) anyerror!void = null,
    resume_device: ?*const fn (*Device) anyerror!void = null,
    reset: ?*const fn (*Device) anyerror!void = null,
    shutdown: ?*const fn (*Device) anyerror!void = null,
};

// Driver operations
pub const DriverOperations = struct {
    probe: ?*const fn (*Driver, *Device) anyerror!bool = null,
    init: ?*const fn (*Driver, *Device) anyerror!void = null,
    deinit: ?*const fn (*Driver, *Device) anyerror!void = null,
    suspend_driver: ?*const fn (*Driver, *Device) anyerror!void = null,
    resume_driver: ?*const fn (*Driver, *Device) anyerror!void = null,
    reset: ?*const fn (*Driver, *Device) anyerror!void = null,
    shutdown: ?*const fn (*Driver, *Device) anyerror!void = null,
    ioctl: ?*const fn (*Driver, *Device, u64, usize) anyerror!usize = null,
    mmap: ?*const fn (*Driver, *Device, usize, usize, u32) anyerror!*u8 = null,
};

// PCI device information
pub const PCIDeviceInfo = struct {
    vendor_id: u16,
    device_id: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,
    revision: u8,
    subsystem_vendor_id: u16,
    subsystem_device_id: u16,
    irq: u8,
    bar: [6]u32,
    bar_flags: [6]u8,
};

// USB device information
pub const USBDeviceInfo = struct {
    vendor_id: u16,
    product_id: u16,
    class: u8,
    subclass: u8,
    protocol: u8,
    configuration_value: u8,
    interface_class: u8,
    interface_subclass: u8,
    interface_protocol: u8,
};

// Device
pub const Device = struct {
    name: []const u8,
    type: DeviceType,
    status: DeviceStatus,
    parent: ?*Device = null,
    children: ?*Device = null,
    next: ?*Device = null,
    driver: ?*Driver = null,
    ops: *const DeviceOperations,
    private_data: ?*anyopaque = null,
    lock: spinlock.RwSpinlock,
    
    // Type-specific information
    pci_info: ?PCIDeviceInfo = null,
    usb_info: ?USBDeviceInfo = null,
    
    pub fn create(name: []const u8, type_param: DeviceType, ops: *const DeviceOperations) Device {
        return .{
            .name = name,
            .type = type_param,
            .status = .Unknown,
            .parent = null,
            .children = null,
            .next = null,
            .driver = null,
            .ops = ops,
            .private_data = null,
            .lock = spinlock.RwSpinlock.init(),
            .pci_info = null,
            .usb_info = null,
        };
    }
    
    pub fn probe(self: *Device) anyerror!bool {
        if (self.ops.probe) |probe_op| {
            return probe_op(self);
        }
        return false;
    }
    
    pub fn init(self: *Device) anyerror!void {
        if (self.ops.init) |init_op| {
            return init_op(self);
        }
    }
    
    pub fn deinit(self: *Device) anyerror!void {
        if (self.ops.deinit) |deinit_op| {
            return deinit_op(self);
        }
    }
    
    pub fn suspend_device(self: *Device) anyerror!void {
        if (self.ops.suspend_device) |suspend_op| {
            return suspend_op(self);
        }
    }
    
    pub fn resume_device(self: *Device) anyerror!void {
        if (self.ops.resume_device) |resume_op| {
            return resume_op(self);
        }
    }
    
    pub fn reset(self: *Device) anyerror!void {
        if (self.ops.reset) |reset_op| {
            return reset_op(self);
        }
    }
    
    pub fn shutdown(self: *Device) anyerror!void {
        if (self.ops.shutdown) |shutdown_op| {
            return shutdown_op(self);
        }
    }
    
    pub fn add_child(self: *Device, child: *Device) void {
        child.parent = self;
        
        if (self.children == null) {
            self.children = child;
        } else {
            var current = self.children;
            while (current.?.next != null) {
                current = current.?.next;
            }
            current.?.next = child;
        }
    }
    
    pub fn remove_child(self: *Device, child: *Device) void {
        var prev: ?*Device = null;
        var current = self.children;
        
        while (current != null) {
            if (current == child) {
                if (prev != null) {
                    prev.?.next = current.?.next;
                } else {
                    self.children = current.?.next;
                }
                current.?.parent = null;
                return;
            }
            prev = current;
            current = current.?.next;
        }
    }
};

// Driver
pub const Driver = struct {
    name: []const u8,
    type: DriverType,
    version: u32,
    flags: DriverFlags,
    ops: *const DriverOperations,
    private_data: ?*anyopaque = null,
    lock: spinlock.RwSpinlock,
    next: ?*Driver = null,
    
    pub fn create(name: []const u8, type_param: DriverType, version: u32, ops: *const DriverOperations) Driver {
        return .{
            .name = name,
            .type = type_param,
            .version = version,
            .flags = .{},
            .ops = ops,
            .private_data = null,
            .lock = spinlock.RwSpinlock.init(),
        };
    }
    
    pub fn probe(self: *Driver, device: *Device) anyerror!bool {
        if (self.ops.probe) |probe_op| {
            return probe_op(self, device);
        }
        return false;
    }
    
    pub fn init(self: *Driver, device: *Device) anyerror!void {
        if (self.ops.init) |init_op| {
            return init_op(self, device);
        }
    }
    
    pub fn deinit(self: *Driver, device: *Device) anyerror!void {
        if (self.ops.deinit) |deinit_op| {
            return deinit_op(self, device);
        }
    }
    
    pub fn suspend_driver(self: *Driver, device: *Device) anyerror!void {
        if (self.ops.suspend_driver) |suspend_op| {
            return suspend_op(self, device);
        }
    }
    
    pub fn resume_driver(self: *Driver, device: *Device) anyerror!void {
        if (self.ops.resume_driver) |resume_op| {
            return resume_op(self, device);
        }
    }
    
    pub fn reset(self: *Driver, device: *Device) anyerror!void {
        if (self.ops.reset) |reset_op| {
            return reset_op(self, device);
        }
    }
    
    pub fn shutdown(self: *Driver, device: *Device) anyerror!void {
        if (self.ops.shutdown) |shutdown_op| {
            return shutdown_op(self, device);
        }
    }
    
    pub fn ioctl(self: *Driver, device: *Device, cmd: u64, arg: usize) anyerror!usize {
        if (self.ops.ioctl) |ioctl_op| {
            return ioctl_op(self, device, cmd, arg);
        }
        return error.NotSupported;
    }
    
    pub fn mmap(self: *Driver, device: *Device, addr: usize, length: usize, prot: u32) anyerror!*u8 {
        if (self.ops.mmap) |mmap_op| {
            return mmap_op(self, device, addr, length, prot);
        }
        return error.NotSupported;
    }
};

// Driver manager
pub const DriverManager = struct {
    drivers: ?*Driver = null,
    devices: ?*Device = null,
    lock: spinlock.RwSpinlock,
    
    pub fn init() DriverManager {
        return .{
            .drivers = null,
            .devices = null,
            .lock = spinlock.RwSpinlock.init(),
        };
    }
    
    pub fn register_driver(self: *DriverManager, driver: *Driver) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Check if driver is already registered
        var current = self.drivers;
        while (current != null) {
            if (std.mem.eql(u8, current.?.name, driver.name)) {
                return error.DriverAlreadyRegistered;
            }
            current = current.?.next;
        }
        
        // Add driver to list
        if (self.drivers == null) {
            self.drivers = driver;
        } else {
            current = self.drivers;
            while (current.?.next != null) {
                current = current.?.next;
            }
            current.?.next = driver;
        }
    }
    
    pub fn unregister_driver(self: *DriverManager, driver: *Driver) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        var prev: ?*Driver = null;
        var current = self.drivers;
        
        while (current != null) {
            if (current == driver) {
                // Remove from list
                if (prev != null) {
                    prev.?.next = current.?.next;
                } else {
                    self.drivers = current.?.next;
                }
                
                // Deinitialize all devices using this driver
                self.deinit_driver_devices(driver);
                
                return;
            }
            prev = current;
            current = current.?.next;
        }
        
        return error.DriverNotFound;
    }
    
    pub fn add_device(self: *DriverManager, device: *Device) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Add device to list
        if (self.devices == null) {
            self.devices = device;
        } else {
            var current = self.devices;
            while (current.?.next != null) {
                current = current.?.next;
            }
            current.?.next = device;
        }
        
        // Try to find a driver for the device
        try self.match_driver(device);
    }
    
    pub fn remove_device(self: *DriverManager, device: *Device) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        var prev: ?*Device = null;
        var current = self.devices;
        
        while (current != null) {
            if (current == device) {
                // Remove from list
                if (prev != null) {
                    prev.?.next = current.?.next;
                } else {
                    self.devices = current.?.next;
                }
                
                // Deinitialize device
                if (current.?.driver != null) {
                    current.?.driver.?.deinit(current.?) catch {};
                }
                
                return;
            }
            prev = current;
            current = current.?.next;
        }
        
        return error.DeviceNotFound;
    }
    
    pub fn probe_devices(self: *DriverManager) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Probe all devices
        var device = self.devices;
        while (device != null) {
            if (device.?.status == .Unknown) {
                const present = device.?.probe() catch false;
                if (present) {
                    device.?.status = .Present;
                    
                    // Try to find a driver for the device
                    self.match_driver(device.?) catch {};
                } else {
                    device.?.status = .Error;
                }
            }
            device = device.?.next;
        }
    }
    
    pub fn init_devices(self: *DriverManager) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Initialize all devices
        var device = self.devices;
        while (device != null) {
            if (device.?.status == .Present and device.?.driver != null) {
                device.?.driver.?.init(device.?) catch {
                    device.?.status = .Error;
                    continue;
                };
                device.?.status = .Enabled;
                device.?.driver.?.flags.running = true;
            }
            device = device.?.next;
        }
    }
    
    pub fn suspend_devices(self: *DriverManager) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Suspend all devices
        var device = self.devices;
        while (device != null) {
            if (device.?.status == .Enabled and device.?.driver != null) {
                device.?.driver.?.suspend_driver(device.?) catch {};
                device.?.status = .Disabled;
                device.?.driver.?.flags.running = false;
            }
            device = device.?.next;
        }
    }
    
    pub fn resume_devices(self: *DriverManager) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Resume all devices
        var device = self.devices;
        while (device != null) {
            if (device.?.status == .Disabled and device.?.driver != null) {
                device.?.driver.?.resume_driver(device.?) catch {
                    device.?.status = .Error;
                    continue;
                };
                device.?.status = .Enabled;
                device.?.driver.?.flags.running = true;
            }
            device = device.?.next;
        }
    }
    
    pub fn shutdown_devices(self: *DriverManager) !void {
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Shutdown all devices
        var device = self.devices;
        while (device != null) {
            if (device.?.driver != null) {
                device.?.driver.?.shutdown(device.?) catch {};
                device.?.status = .Disabled;
                device.?.driver.?.flags.running = false;
            }
            device = device.?.next;
        }
    }
    
    fn match_driver(self: *DriverManager, device: *Device) !void {
        var driver = self.drivers;
        while (driver != null) {
            if (driver.?.probe(device.?)) {
                device.?.driver = driver.?;
                return;
            }
            driver = driver.?.next;
        }
    }
    
    fn deinit_driver_devices(self: *DriverManager, driver: *Driver) void {
        var device = self.devices;
        while (device != null) {
            if (device.?.driver == driver) {
                driver.deinit(device.?) catch {};
                device.?.driver = null;
                device.?.status = .Present;
            }
            device = device.?.next;
        }
    }
};

// PCI driver
pub const PCIDriver = struct {
    driver: Driver,
    
    pub fn init() PCIDriver {
        const driver_ops = DriverOperations{
            .probe = pci_probe,
            .init = pci_init,
            .deinit = pci_deinit,
            .suspend_driver = pci_suspend,
            .resume_driver = pci_resume,
            .reset = pci_reset,
            .shutdown = pci_shutdown,
            .ioctl = pci_ioctl,
            .mmap = pci_mmap,
        };
        
        return .{
            .driver = Driver.create("PCI", .Bus, 1, &driver_ops),
        };
    }
};

fn pci_probe(driver: *Driver, device: *Device) anyerror!bool {
    _ = driver;
    
    // Check if device is a PCI device
    if (device.type != .PCI) {
        return false;
    }
    
    // Check if PCI info is available
    if (device.pci_info == null) {
        return false;
    }
    
    // TODO: Implement PCI device probing
    return true;
}

fn pci_init(driver: *Driver, device: *Device) anyerror!void {
    _ = driver;
    
    // TODO: Implement PCI device initialization
    const pci_info = device.pci_info.?;
    
    // Enable PCI device
    const config_addr = 0x80000000 | (@as(u32, pci_info.device_id) << 16) | (@as(u32, pci_info.vendor_id));
    arch.outl(0xCF8, config_addr);
    
    // Read command register
    var command = arch.inl(0xCFC) & 0xFFFF;
    
    // Enable I/O and memory space
    command |= 0x03;
    
    // Write back command register
    arch.outl(0xCFC, command);
}

fn pci_deinit(driver: *Driver, device: *Device) anyerror!void {
    _ = driver;
    _ = device;
    
    // TODO: Implement PCI device deinitialization
}

fn pci_suspend(driver: *Driver, device: *Device) anyerror!void {
    _ = driver;
    _ = device;
    
    // TODO: Implement PCI device suspension
}

fn pci_resume(driver: *Driver, device: *Device) anyerror!void {
    _ = driver;
    _ = device;
    
    // TODO: Implement PCI device resumption
}

fn pci_reset(driver: *Driver, device: *Device) anyerror!void {
    _ = driver;
    _ = device;
    
    // TODO: Implement PCI device reset
}

fn pci_shutdown(driver: *Driver, device: *Device) anyerror!void {
    _ = driver;
    _ = device;
    
    // TODO: Implement PCI device shutdown
}

fn pci_ioctl(driver: *Driver, device: *Device, cmd: u64, arg: usize) anyerror!usize {
    _ = driver;
    _ = device;
    _ = cmd;
    _ = arg;
    
    // TODO: Implement PCI device ioctl
    return 0;
}

fn pci_mmap(driver: *Driver, device: *Device, addr: usize, length: usize, prot: u32) anyerror!*u8 {
    _ = driver;
    _ = device;
    _ = addr;
    _ = length;
    _ = prot;
    
    // TODO: Implement PCI device mmap
    return error.NotSupported;
}

// Global driver manager
var global_driver_manager: DriverManager = undefined;

// Initialize the driver manager
pub fn init() !void {
    global_driver_manager = DriverManager.init();
    
    // Register PCI driver
    var pci_driver = PCIDriver.init();
    try global_driver_manager.register_driver(&pci_driver.driver);
    
    // TODO: Register other drivers
    
    // Probe and initialize devices
    try global_driver_manager.probe_devices();
    try global_driver_manager.init_devices();
}

// Register a driver
pub fn register_driver(driver: *Driver) !void {
    try global_driver_manager.register_driver(driver);
}

// Unregister a driver
pub fn unregister_driver(driver: *Driver) !void {
    try global_driver_manager.unregister_driver(driver);
}

// Add a device
pub fn add_device(device: *Device) !void {
    try global_driver_manager.add_device(device);
}

// Remove a device
pub fn remove_device(device: *Device) !void {
    try global_driver_manager.remove_device(device);
}

// Probe all devices
pub fn probe_devices() !void {
    try global_driver_manager.probe_devices();
}

// Initialize all devices
pub fn init_devices() !void {
    try global_driver_manager.init_devices();
}

// Suspend all devices
pub fn suspend_devices() !void {
    try global_driver_manager.suspend_devices();
}

// Resume all devices
pub fn resume_devices() !void {
    try global_driver_manager.resume_devices();
}

// Shutdown all devices
pub fn shutdown_devices() !void {
    try global_driver_manager.shutdown_devices();
}