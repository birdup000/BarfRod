// Timer and clock implementation for the redesigned kernel
const std = @import("std");
const arch = @import("arch.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const process = @import("process.zig");
const interrupts = @import("interrupts.zig");
const spinlock = @import("spinlock.zig");
const kheap = @import("kheap.zig");

// Timer types
pub const TimerType = enum {
    PIT,        // Programmable Interval Timer
    APIC,       // Local APIC Timer
    HPET,       // High Precision Event Timer
    TSC,        // Time Stamp Counter
    RTC,        // Real Time Clock
};

// Timer modes
pub const TimerMode = enum {
    OneShot,
    Periodic,
    RateGenerator,
    SquareWave,
};

// Timer configuration
pub const TimerConfig = struct {
    type: TimerType,
    frequency: u32,
    mode: TimerMode,
    enabled: bool,
};

// Timer statistics
pub const TimerStats = struct {
    interrupts: u64,
    overflows: u64,
    last_interrupt_time: u64,
    average_interval: u64,
};

// Timer operations
pub const TimerOperations = struct {
    init: ?*const fn (*Timer) anyerror!void = null,
    deinit: ?*const fn (*Timer) anyerror!void = null,
    start: ?*const fn (*Timer) anyerror!void = null,
    stop: ?*const fn (*Timer) anyerror!void = null,
    set_frequency: ?*const fn (*Timer, u32) anyerror!void = null,
    set_mode: ?*const fn (*Timer, TimerMode) anyerror!void = null,
    get_count: ?*const fn (*Timer) anyerror!u64 = null,
    set_count: ?*const fn (*Timer, u64) anyerror!void = null,
    get_stats: ?*const fn (*Timer) anyerror!TimerStats = null,
    reset_stats: ?*const fn (*Timer) anyerror!void = null,
};

// Timer
pub const Timer = struct {
    name: []const u8,
    type: TimerType,
    config: TimerConfig,
    ops: *const TimerOperations,
    private_data: ?*anyopaque = null,
    lock: spinlock.Spinlock,
    next: ?*Timer = null,
    
    pub fn init(name: []const u8, timer_type: TimerType, ops: *const TimerOperations) Timer {
        return .{
            .name = name,
            .type = timer_type,
            .config = .{
                .type = timer_type,
                .frequency = 1000, // Default 1kHz
                .mode = .Periodic,
                .enabled = false,
            },
            .ops = ops,
            .private_data = null,
            .lock = spinlock.Spinlock.init(),
        };
    }
    
    pub fn init_device(self: *Timer) anyerror!void {
        if (self.ops.init) |init_op| {
            return init_op(self);
        }
    }
    
    pub fn deinit(self: *Timer) anyerror!void {
        if (self.ops.deinit) |deinit_op| {
            return deinit_op(self);
        }
    }
    
    pub fn start(self: *Timer) anyerror!void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.ops.start) |start_op| {
            try start_op(self);
            self.config.enabled = true;
        }
    }
    
    pub fn stop(self: *Timer) anyerror!void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.ops.stop) |stop_op| {
            try stop_op(self);
            self.config.enabled = false;
        }
    }
    
    pub fn set_frequency(self: *Timer, frequency: u32) anyerror!void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.ops.set_frequency) |set_frequency_op| {
            try set_frequency_op(self, frequency);
            self.config.frequency = frequency;
        }
    }
    
    pub fn set_mode(self: *Timer, mode: TimerMode) anyerror!void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.ops.set_mode) |set_mode_op| {
            try set_mode_op(self, mode);
            self.config.mode = mode;
        }
    }
    
    pub fn get_count(self: *Timer) anyerror!u64 {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.ops.get_count) |get_count_op| {
            return get_count_op(self);
        }
        return 0;
    }
    
    pub fn set_count(self: *Timer, count: u64) anyerror!void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.ops.set_count) |set_count_op| {
            return set_count_op(self, count);
        }
    }
    
    pub fn get_stats(self: *Timer) anyerror!TimerStats {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.ops.get_stats) |get_stats_op| {
            return get_stats_op(self);
        }
        return TimerStats{
            .interrupts = 0,
            .overflows = 0,
            .last_interrupt_time = 0,
            .average_interval = 0,
        };
    }
    
    pub fn reset_stats(self: *Timer) anyerror!void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.ops.reset_stats) |reset_stats_op| {
            return reset_stats_op(self);
        }
    }
};

// Clock source
pub const ClockSource = struct {
    name: []const u8,
    rating: i32, // Higher is better
    read: *const fn () u64,
    mask: u64,
    mult: u32,
    shift: u8,
    flags: u32,
};

// Clock source flags
pub const CLOCK_SOURCE_IS_CONTINUOUS: u32 = 1 << 0;
pub const CLOCK_SOURCE_VALID_FOR_HRES: u32 = 1 << 1;
pub const CLOCK_SOURCE_UNSTABLE: u32 = 1 << 2;
pub const CLOCK_SOURCE_SUSPEND_NONSTOP: u32 = 1 << 3;

// Timekeeper
pub const Timekeeper = struct {
    clock: ?*ClockSource = null,
    cycle_last: u64 = 0,
    ntp_error: i64 = 0,
    ntp_error_shift: u8 = 0,
    xtime_interval: u64 = 0,
    xtime_remainder: u64 = 0,
    raw_interval: u64 = 0,
    lock: spinlock.Spinlock,
    
    pub fn init() Timekeeper {
        return .{
            .clock = null,
            .cycle_last = 0,
            .ntp_error = 0,
            .ntp_error_shift = 0,
            .xtime_interval = 0,
            .xtime_remainder = 0,
            .raw_interval = 0,
            .lock = spinlock.Spinlock.init(),
        };
    }
    
    pub fn register_clock(self: *Timekeeper, clock: *ClockSource) void {
        self.lock.acquire();
        defer self.lock.release();
        
        // Use the best clock source
        if (self.clock == null or clock.rating > self.clock.?.rating) {
            self.clock = clock;
            self.cycle_last = self.read_clock();
        }
    }
    
    pub fn unregister_clock(self: *Timekeeper, clock: *ClockSource) void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.clock == clock) {
            self.clock = null;
            // TODO: Find next best clock source
        }
    }
    
    pub fn read_clock(self: *Timekeeper) u64 {
        if (self.clock) |clock| {
            return clock.read();
        }
        return 0;
    }
    
    pub fn get_time_ns(self: *Timekeeper) u64 {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.clock == null) {
            return 0;
        }
        
        const now = self.read_clock();
        const delta = now - self.cycle_last;
        
        // Convert cycles to nanoseconds
        const ns = (delta * self.clock.?.mult) >> self.clock.?.shift;
        
        return ns;
    }
    
    pub fn update(self: *Timekeeper) void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.clock == null) {
            return;
        }
        
        const now = self.read_clock();
        const delta = now - self.cycle_last;
        
        // Update cycle_last
        self.cycle_last = now;
        
        // Update time
        const ns = (delta * self.clock.?.mult) >> self.clock.?.shift;
        
        // TODO: Update xtime
        _ = ns;
    }
};

// System time
pub const SystemTime = struct {
    seconds: u64,
    nanoseconds: u32,
    
    pub fn init() SystemTime {
        return .{
            .seconds = 0,
            .nanoseconds = 0,
        };
    }
    
    pub fn add_ns(self: *SystemTime, ns: u64) void {
        self.seconds += ns / 1000000000;
        self.nanoseconds += @as(u32, @intCast(ns % 1000000000));
        
        if (self.nanoseconds >= 1000000000) {
            self.seconds += 1;
            self.nanoseconds -= 1000000000;
        }
    }
    
    pub fn to_ns(self: *const SystemTime) u64 {
        return self.seconds * 1000000000 + self.nanoseconds;
    }
};

// Timer manager
pub const TimerManager = struct {
    timers: ?*Timer = null,
    system_timer: ?*Timer = null,
    timekeeper: Timekeeper,
    system_time: SystemTime,
    tick_rate: u32,
    ticks: u64,
    lock: spinlock.Spinlock,
    
    pub fn init() TimerManager {
        return .{
            .timers = null,
            .system_timer = null,
            .timekeeper = Timekeeper.init(),
            .system_time = SystemTime.init(),
            .tick_rate = 1000, // Default 1kHz
            .ticks = 0,
            .lock = spinlock.Spinlock.init(),
        };
    }
    
    pub fn register_timer(self: *TimerManager, timer: *Timer) !void {
        self.lock.acquire();
        defer self.lock.release();
        
        // Add timer to list
        if (self.timers == null) {
            self.timers = timer;
        } else {
            var current = self.timers;
            while (current.?.next != null) {
                current = current.?.next;
            }
            current.?.next = timer;
        }
        
        // Initialize timer
        try timer.init_device();
    }
    
    pub fn unregister_timer(self: *TimerManager, timer: *Timer) !void {
        self.lock.acquire();
        defer self.lock.release();
        
        var prev: ?*Timer = null;
        var current = self.timers;
        
        while (current != null) {
            if (current == timer) {
                // Remove from list
                if (prev != null) {
                    prev.?.next = current.?.next;
                } else {
                    self.timers = current.?.next;
                }
                
                // Deinitialize timer
                try timer.deinit();
                
                // If this was the system timer, clear it
                if (self.system_timer == timer) {
                    self.system_timer = null;
                }
                
                return;
            }
            prev = current;
            current = current.?.next;
        }
        
        return error.TimerNotFound;
    }
    
    pub fn set_system_timer(self: *TimerManager, timer: *Timer) !void {
        self.lock.acquire();
        defer self.lock.release();
        
        // Check if timer is registered
        var current = self.timers;
        var found = false;
        
        while (current != null) {
            if (current == timer) {
                found = true;
                break;
            }
            current = current.?.next;
        }
        
        if (!found) {
            return error.TimerNotRegistered;
        }
        
        // Stop current system timer
        if (self.system_timer != null) {
            try self.system_timer.?.stop();
        }
        
        // Set new system timer
        self.system_timer = timer;
        self.tick_rate = timer.config.frequency;
        
        // Start new system timer
        try timer.start();
    }
    
    pub fn handle_interrupt(self: *TimerManager) void {
        self.lock.acquire();
        defer self.lock.release();
        
        // Update tick count
        self.ticks += 1;
        
        // Update system time
        self.system_time.add_ns(1000000000 / self.tick_rate);
        
        // Update timekeeper
        self.timekeeper.update();
        
        // Schedule processes
        const manager = process.get_manager();
        _ = manager; // TODO: Implement tick function
    }
    
    pub fn get_ticks(self: *TimerManager) u64 {
        self.lock.acquire();
        defer self.lock.release();
        
        return self.ticks;
    }
    
    pub fn get_system_time(self: *TimerManager) SystemTime {
        self.lock.acquire();
        defer self.lock.release();
        
        return self.system_time;
    }
    
    pub fn get_time_ns(self: *TimerManager) u64 {
        self.lock.acquire();
        defer self.lock.release();
        
        return self.system_time.to_ns();
    }
    
    pub fn get_time_ms(self: *TimerManager) u64 {
        return self.get_time_ns() / 1000000;
    }
    
    pub fn get_time_s(self: *TimerManager) u64 {
        return self.get_time_ns() / 1000000000;
    }
    
    pub fn sleep_ms(self: *TimerManager, ms: u64) void {
        const start_ticks = self.get_ticks();
        const ticks_to_wait = (ms * self.tick_rate) / 1000;
        
        while (self.get_ticks() - start_ticks < ticks_to_wait) {
            arch.halt();
        }
    }
    
    pub fn sleep_s(self: *TimerManager, s: u64) void {
        self.sleep_ms(s * 1000);
    }
};

// PIT timer
pub const PITTimer = struct {
    timer: Timer,
    
    pub fn init() PITTimer {
        const timer_ops = TimerOperations{
            .init = pit_init,
            .deinit = pit_deinit,
            .start = pit_start,
            .stop = pit_stop,
            .set_frequency = pit_set_frequency,
            .set_mode = pit_set_mode,
            .get_count = pit_get_count,
            .set_count = pit_set_count,
            .get_stats = pit_get_stats,
            .reset_stats = pit_reset_stats,
        };
        
        return .{
            .timer = Timer.init("PIT", .PIT, &timer_ops),
        };
    }
};

// PIT registers
const PIT_REG_COMMAND: u16 = 0x43;
const PIT_REG_COUNTER0: u16 = 0x40;
const PIT_REG_COUNTER1: u16 = 0x41;
const PIT_REG_COUNTER2: u16 = 0x42;

// PIT command bits
const PIT_CMD_SELECT_MASK: u8 = 0xC0;
const PIT_CMD_SELECT_COUNTER0: u8 = 0x00;
const PIT_CMD_SELECT_COUNTER1: u8 = 0x40;
const PIT_CMD_SELECT_COUNTER2: u8 = 0x80;
const PIT_CMD_READ_BACK: u8 = 0xC0;

const PIT_CMD_ACCESS_MASK: u8 = 0x30;
const PIT_CMD_ACCESS_LATCH: u8 = 0x00;
const PIT_CMD_ACCESS_LOW: u8 = 0x10;
const PIT_CMD_ACCESS_HIGH: u8 = 0x20;
const PIT_CMD_ACCESS_LOWHIGH: u8 = 0x30;

const PIT_CMD_MODE_MASK: u8 = 0x0E;
const PIT_CMD_MODE_TERMINAL_COUNT: u8 = 0x00;
const PIT_CMD_MODE_ONE_SHOT: u8 = 0x02;
const PIT_CMD_MODE_RATE_GENERATOR: u8 = 0x04;
const PIT_CMD_MODE_SQUARE_WAVE: u8 = 0x06;
const PIT_CMD_MODE_SOFTWARE_STROBE: u8 = 0x08;
const PIT_CMD_MODE_HARDWARE_STROBE: u8 = 0x0A;

const PIT_CMD_BCD: u8 = 0x01;

// PIT base frequency
const PIT_BASE_FREQUENCY: u32 = 1193182;

// PIT private data
const PITPrivateData = struct {
    frequency: u32,
    divisor: u16,
    stats: TimerStats,
};

fn pit_init(timer: *Timer) anyerror!void {
    // Allocate private data
    const private_data = try kheap.alloc(@sizeOf(PITPrivateData), 8);
    private_data.* = .{
        .frequency = timer.config.frequency,
        .divisor = @as(u16, @intCast(PIT_BASE_FREQUENCY / timer.config.frequency)),
        .stats = .{
            .interrupts = 0,
            .overflows = 0,
            .last_interrupt_time = 0,
            .average_interval = 0,
        },
    };
    
    timer.private_data = private_data;
    
    // Set up PIT
    arch.outb(PIT_REG_COMMAND, PIT_CMD_SELECT_COUNTER0 | PIT_CMD_ACCESS_LOWHIGH | PIT_CMD_MODE_SQUARE_WAVE);
    
    // Set divisor
    arch.outb(PIT_REG_COUNTER0, @as(u8, @intCast(private_data.divisor & 0xFF)));
    arch.outb(PIT_REG_COUNTER0, @as(u8, @intCast((private_data.divisor >> 8) & 0xFF)));
}

fn pit_deinit(timer: *Timer) anyerror!void {
    if (timer.private_data) |private_data| {
        kheap.free(private_data);
        timer.private_data = null;
    }
}

fn pit_start(__timer: *Timer) anyerror!void {
    _ = __timer;
    // PIT starts automatically when initialized
}

fn pit_stop(__timer: *Timer) anyerror!void {
    _ = __timer;
    // PIT cannot be stopped, but we can set it to a very low frequency
    arch.outb(PIT_REG_COMMAND, PIT_CMD_SELECT_COUNTER0 | PIT_CMD_ACCESS_LOWHIGH | PIT_CMD_MODE_TERMINAL_COUNT);
    arch.outb(PIT_REG_COUNTER0, 0);
    arch.outb(PIT_REG_COUNTER0, 0);
}

fn pit_set_frequency(timer: *Timer, frequency: u32) anyerror!void {
    if (timer.private_data) |private_data| {
        const private = @as(*PITPrivateData, @ptrCast(private_data));
        private.frequency = frequency;
        private.divisor = @as(u16, @intCast(PIT_BASE_FREQUENCY / frequency));
        
        // Set new divisor
        arch.outb(PIT_REG_COMMAND, PIT_CMD_SELECT_COUNTER0 | PIT_CMD_ACCESS_LOWHIGH | PIT_CMD_MODE_SQUARE_WAVE);
        arch.outb(PIT_REG_COUNTER0, @as(u8, @intCast(private.divisor & 0xFF)));
        arch.outb(PIT_REG_COUNTER0, @as(u8, @intCast((private.divisor >> 8) & 0xFF)));
    }
}

fn pit_set_mode(__timer: *Timer, mode: TimerMode) anyerror!void {
    _ = __timer;
    const pit_mode = switch (mode) {
        .OneShot => PIT_CMD_MODE_ONE_SHOT,
        .Periodic => PIT_CMD_MODE_SQUARE_WAVE,
        .RateGenerator => PIT_CMD_MODE_RATE_GENERATOR,
        .SquareWave => PIT_CMD_MODE_SQUARE_WAVE,
    };
    
    arch.outb(PIT_REG_COMMAND, PIT_CMD_SELECT_COUNTER0 | PIT_CMD_ACCESS_LOWHIGH | pit_mode);
}

fn pit_get_count(timer: *Timer) anyerror!u64 {
    if (timer.private_data) |private_data| {
        const private = @as(*PITPrivateData, @ptrCast(private_data));
        
        // Latch counter value
        arch.outb(PIT_REG_COMMAND, PIT_CMD_SELECT_COUNTER0 | PIT_CMD_ACCESS_LATCH);
        
        // Read counter value
        const low = arch.inb(PIT_REG_COUNTER0);
        const high = arch.inb(PIT_REG_COUNTER0);
        const count = (@as(u16, high) << 8) | low;
        
        // Convert to cycles
        return @as(u64, count) * (@as(u64, PIT_BASE_FREQUENCY) / private.frequency);
    }
    return 0;
}

fn pit_set_count(timer: *Timer, count: u64) anyerror!void {
    if (timer.private_data) |private_data| {
        const private = @as(*PITPrivateData, @ptrCast(private_data));
        
        // Convert to divisor
        const divisor = @as(u16, @intCast(count / (@as(u64, PIT_BASE_FREQUENCY) / private.frequency)));
        
        // Set divisor
        arch.outb(PIT_REG_COMMAND, PIT_CMD_SELECT_COUNTER0 | PIT_CMD_ACCESS_LOWHIGH | PIT_CMD_MODE_SQUARE_WAVE);
        arch.outb(PIT_REG_COUNTER0, @as(u8, @intCast(divisor & 0xFF)));
        arch.outb(PIT_REG_COUNTER0, @as(u8, @intCast((divisor >> 8) & 0xFF)));
    }
}

fn pit_get_stats(timer: *Timer) anyerror!TimerStats {
    if (timer.private_data) |private_data| {
        const private = @as(*PITPrivateData, @ptrCast(private_data));
        return private.stats;
    }
    return TimerStats{
        .interrupts = 0,
        .overflows = 0,
        .last_interrupt_time = 0,
        .average_interval = 0,
    };
}

fn pit_reset_stats(timer: *Timer) anyerror!void {
    if (timer.private_data) |private_data| {
        const private = @as(*PITPrivateData, @ptrCast(private_data));
        private.stats = .{
            .interrupts = 0,
            .overflows = 0,
            .last_interrupt_time = 0,
            .average_interval = 0,
        };
    }
}

// TSC clock source
fn tsc_read() u64 {
    return arch.read_msr(0x10); // TSC
}

const tsc_clock_source = ClockSource{
    .name = "TSC",
    .rating = 300,
    .read = tsc_read,
    .mask = 0xFFFFFFFFFFFFFFFF,
    .mult = 1,
    .shift = 0,
    .flags = CLOCK_SOURCE_IS_CONTINUOUS | CLOCK_SOURCE_VALID_FOR_HRES,
};

// Global timer manager
var global_timer_manager: TimerManager = undefined;

// Initialize the timer manager
pub fn init() !void {
    global_timer_manager = TimerManager.init();
    
    // Register TSC clock source
    global_timer_manager.timekeeper.register_clock(@constCast(&tsc_clock_source));
    
    // Register PIT timer
    var pit_timer = PITTimer.init();
    try global_timer_manager.register_timer(&pit_timer.timer);
    
    // Set PIT as system timer
    try global_timer_manager.set_system_timer(&pit_timer.timer);
    
    // Enable timer interrupt
    interrupts.enable_irq(0);
}

// Register a timer
pub fn register_timer(timer: *Timer) !void {
    try global_timer_manager.register_timer(timer);
}

// Unregister a timer
pub fn unregister_timer(timer: *Timer) !void {
    try global_timer_manager.unregister_timer(timer);
}

// Set system timer
pub fn set_system_timer(timer: *Timer) !void {
    try global_timer_manager.set_system_timer(timer);
}

// Handle timer interrupt
pub fn handle_interrupt() void {
    global_timer_manager.handle_interrupt();
}

// Get ticks
pub fn get_ticks() u64 {
    return global_timer_manager.get_ticks();
}

// Get system time
pub fn get_system_time() SystemTime {
    return global_timer_manager.get_system_time();
}

// Get time in nanoseconds
pub fn get_time_ns() u64 {
    return global_timer_manager.get_time_ns();
}

// Get time in milliseconds
pub fn get_time_ms() u64 {
    return global_timer_manager.get_time_ms();
}

// Get time in seconds
pub fn get_time_s() u64 {
    return global_timer_manager.get_time_s();
}

// Sleep for milliseconds
pub fn sleep_ms(ms: u64) void {
    global_timer_manager.sleep_ms(ms);
}

// Sleep for seconds
pub fn sleep_s(s: u64) void {
    global_timer_manager.sleep_s(s);
}