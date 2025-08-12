// Spinlock implementation for kernel synchronization
const std = @import("std");
const arch = @import("arch.zig");

pub const Spinlock = struct {
    locked: u8,
    
    pub fn init() Spinlock {
        return .{ .locked = 0 };
    }
    
    pub fn acquire(self: *Spinlock) void {
        // Disable interrupts to prevent deadlocks with ISRs
        const flags = arch.read_rflags();
        arch.disable_interrupts();
        
        // Try to acquire the lock
        while (true) {
            if (@cmpxchgWeak(u8, &self.locked, 0, 1, .acquire, .monotonic) == null) {
                // Lock acquired
                break;
            }
            
            // Pause to reduce bus contention
            arch.pause();
        }
        
        // Store interrupt state in the lock (bit 1)
        self.locked |= @as(u8, @intCast((flags & (1 << 9)) >> 8));
    }
    
    pub fn release(self: *Spinlock) void {
        // Get interrupt state
        const restore_interrupts = (self.locked & 2) != 0;
        
        // Release the lock
        @atomicStore(u8, &self.locked, 0, .release);
        
        // Restore interrupts if they were enabled
        if (restore_interrupts) {
            arch.enable_interrupts();
        }
    }
    
    pub fn try_acquire(self: *Spinlock) bool {
        const flags = arch.read_rflags();
        arch.disable_interrupts();
        
        if (@cmpxchgWeak(u8, &self.locked, 0, 1, .acquire, .monotonic) == null) {
            // Lock acquired
            self.locked |= @as(u8, @intCast((flags & (1 << 9)) >> 8));
            return true;
        }
        
        // Restore interrupts
        if ((flags & (1 << 9)) != 0) {
            arch.enable_interrupts();
        }
        
        return false;
    }
    
    pub fn is_locked(self: *const Spinlock) bool {
        return (self.locked & 1) != 0;
    }
};

// Recursive spinlock that can be acquired multiple times by the same CPU
pub const RecursiveSpinlock = struct {
    lock: Spinlock,
    owner: ?*anyopaque, // CPU ID or thread ID
    count: u32,
    
    pub fn init() RecursiveSpinlock {
        return .{
            .lock = Spinlock.init(),
            .owner = null,
            .count = 0,
        };
    }
    
    pub fn acquire(self: *RecursiveSpinlock) void {
        const current_cpu = @as(*anyopaque, @ptrFromInt(0)); // TODO: Get actual CPU ID
        
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.owner == current_cpu) {
            // Already owned by this CPU
            self.count += 1;
        } else {
            // Wait for lock to be released
            while (self.owner != null) {
                self.lock.release();
                arch.pause();
                self.lock.acquire();
            }
            
            // Acquire the lock
            self.owner = current_cpu;
            self.count = 1;
        }
    }
    
    pub fn release(self: *RecursiveSpinlock) void {
        const current_cpu = @as(*anyopaque, @ptrFromInt(0)); // TODO: Get actual CPU ID
        
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.owner != current_cpu) {
            // Not owned by this CPU
            return;
        }
        
        self.count -= 1;
        if (self.count == 0) {
            self.owner = null;
        }
    }
    
    pub fn is_locked(self: *const RecursiveSpinlock) bool {
        return self.owner != null;
    }
};

// Read-write spinlock for multiple readers or single writer
pub const RwSpinlock = struct {
    readers: u32,
    writer: u8,
    write_waiters: u32,
    lock: Spinlock,
    
    pub fn init() RwSpinlock {
        return .{
            .readers = 0,
            .writer = 0,
            .write_waiters = 0,
            .lock = Spinlock.init(),
        };
    }
    
    pub fn acquire_read(self: *RwSpinlock) void {
        self.lock.acquire();
        defer self.lock.release();
        
        // Wait if there's a writer or waiting writers
        while (self.writer != 0 or self.write_waiters > 0) {
            self.lock.release();
            arch.pause();
            self.lock.acquire();
        }
        
        // Acquire read lock
        self.readers += 1;
    }
    
    pub fn release_read(self: *RwSpinlock) void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.readers > 0) {
            self.readers -= 1;
        }
    }
    
    pub fn acquire_write(self: *RwSpinlock) void {
        self.lock.acquire();
        defer self.lock.release();
        
        // Mark as waiting writer
        self.write_waiters += 1;
        
        // Wait for readers and current writer to finish
        while (self.readers > 0 or self.writer != 0) {
            self.lock.release();
            arch.pause();
            self.lock.acquire();
        }
        
        // Acquire write lock
        self.write_waiters -= 1;
        self.writer = 1;
    }
    
    pub fn release_write(self: *RwSpinlock) void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.writer != 0) {
            self.writer = 0;
        }
    }
    
    pub fn try_upgrade_read_to_write(self: *RwSpinlock) bool {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.readers == 1 and self.writer == 0 and self.write_waiters == 0) {
            // Can upgrade
            self.readers = 0;
            self.writer = 1;
            return true;
        }
        
        return false;
    }
    
    pub fn downgrade_write_to_read(self: *RwSpinlock) void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.writer != 0) {
            self.writer = 0;
            self.readers = 1;
        }
    }
    
    pub fn is_locked(self: *const RwSpinlock) bool {
        return self.writer != 0 or self.readers > 0;
    }
    
    pub fn try_acquire_read(self: *RwSpinlock) bool {
        self.lock.acquire();
        defer self.lock.release();
        
        // Check if there's a writer or waiting writers
        if (self.writer != 0 or self.write_waiters > 0) {
            return false;
        }
        
        // Acquire read lock
        self.readers += 1;
        return true;
    }
    
    pub fn try_acquire_write(self: *RwSpinlock) bool {
        self.lock.acquire();
        defer self.lock.release();
        
        // Check if there are any readers or a writer
        if (self.readers != 0 or self.writer != 0) {
            return false;
        }
        
        // Acquire write lock
        self.writer = 1;
        return true;
    }
};

// Ticket spinlock for fairness
pub const TicketSpinlock = struct {
    next_ticket: u32,
    current_ticket: u32,
    
    pub fn init() TicketSpinlock {
        return .{
            .next_ticket = 0,
            .current_ticket = 0,
        };
    }
    
    pub fn acquire(self: *TicketSpinlock) void {
        const flags = arch.read_rflags();
        arch.disable_interrupts();
        
        // Get my ticket
        const my_ticket = @atomicRmw(u32, &self.next_ticket, .Add, 1, .acquire);
        
        // Wait for my turn
        while (@atomicLoad(u32, &self.current_ticket, .acquire) != my_ticket) {
            arch.pause();
        }
        
        // Store interrupt state
        _ = flags; // TODO: Store interrupt state
    }
    
    pub fn release(self: *TicketSpinlock) void {
        // Move to next ticket
        @atomicStore(u32, &self.current_ticket, self.current_ticket + 1, .release);
        
        // TODO: Restore interrupts if they were enabled
    }
    
    pub fn try_acquire(self: *TicketSpinlock) bool {
        const flags = arch.read_rflags();
        arch.disable_interrupts();
        
        const my_ticket = @atomicRmw(u32, &self.next_ticket, .Add, 1, .acquire);
        
        if (@atomicLoad(u32, &self.current_ticket, .acquire) == my_ticket) {
            // Got the lock
            _ = flags; // TODO: Store interrupt state
            return true;
        } else {
            // Didn't get the lock, give back ticket
            // This is not ideal but ensures fairness
            // TODO: Restore interrupts
            return false;
        }
    }
};

// Mutex with sleep support (requires scheduler)
pub const Mutex = struct {
    locked: u8,
    wait_queue: ?*anyopaque, // Thread queue
    lock: Spinlock,
    
    pub fn init() Mutex {
        return .{
            .locked = 0,
            .wait_queue = null,
            .lock = Spinlock.init(),
        };
    }
    
    pub fn acquire(self: *Mutex) void {
        // TODO: Implement with scheduler support
        // For now, use spinlock behavior
        self.lock.acquire();
        defer self.lock.release();
        
        while (self.locked != 0) {
            self.lock.release();
            arch.pause();
            self.lock.acquire();
        }
        
        self.locked = 1;
    }
    
    pub fn release(self: *Mutex) void {
        self.lock.acquire();
        defer self.lock.release();
        
        self.locked = 0;
        
        // TODO: Wake up waiting threads
    }
    
    pub fn try_acquire(self: *Mutex) bool {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.locked == 0) {
            self.locked = 1;
            return true;
        }
        
        return false;
    }
    
    pub fn is_locked(self: *const Mutex) bool {
        return self.locked != 0;
    }
};

// Semaphore implementation
pub const Semaphore = struct {
    count: i32,
    max_count: i32,
    wait_queue: ?*anyopaque, // Thread queue
    lock: Spinlock,
    
    pub fn init(initial_count: i32, max_count: i32) Semaphore {
        return .{
            .count = initial_count,
            .max_count = max_count,
            .wait_queue = null,
            .lock = Spinlock.init(),
        };
    }
    
    pub fn wait(self: *Semaphore) void {
        self.lock.acquire();
        defer self.lock.release();
        
        while (self.count <= 0) {
            // TODO: Sleep with scheduler support
            self.lock.release();
            arch.pause();
            self.lock.acquire();
        }
        
        self.count -= 1;
    }
    
    pub fn signal(self: *Semaphore) void {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.count < self.max_count) {
            self.count += 1;
            
            // TODO: Wake up waiting thread
        }
    }
    
    pub fn try_wait(self: *Semaphore) bool {
        self.lock.acquire();
        defer self.lock.release();
        
        if (self.count > 0) {
            self.count -= 1;
            return true;
        }
        
        return false;
    }
    
    pub fn get_count(self: *const Semaphore) i32 {
        return self.count;
    }
    
    pub fn get_value(self: *const Semaphore) i32 {
        return self.count;
    }
    
    pub fn post(self: *Semaphore) void {
        self.signal();
    }
};

// Condition variable implementation
pub const ConditionVariable = struct {
    wait_queue: ?*anyopaque, // Thread queue
    lock: Spinlock,
    
    pub fn init() ConditionVariable {
        return .{
            .wait_queue = null,
            .lock = Spinlock.init(),
        };
    }
    
    pub fn wait(_self: *ConditionVariable, _mutex: *Mutex) void {
        // TODO: Implement with scheduler support
        // For now, just yield
        _ = _self;
        _ = _mutex;
    }
    
    pub fn signal(_self: *ConditionVariable) void {
        // TODO: Wake up one waiting thread
        _ = _self;
    }
    
    pub fn broadcast(_self: *ConditionVariable) void {
        // TODO: Wake up all waiting threads
        _ = _self;
    }
};

// Barrier for thread synchronization
pub const Barrier = struct {
    count: u32,
    expected: u32,
    lock: Spinlock,
    condition: ConditionVariable,
    
    pub fn init(expected: u32) Barrier {
        return .{
            .count = 0,
            .expected = expected,
            .lock = Spinlock.init(),
            .condition = ConditionVariable.init(),
        };
    }
    
    pub fn wait(self: *Barrier) void {
        self.lock.acquire();
        defer self.lock.release();
        
        self.count += 1;
        
        if (self.count == self.expected) {
            // Last thread to arrive
            self.count = 0;
            self.condition.broadcast();
        } else {
            // Wait for others
            while (self.count < self.expected) {
                self.condition.wait(&Mutex.init()); // Temporary
            }
        }
    }
    
    pub fn reset(self: *Barrier) void {
        self.lock.acquire();
        defer self.lock.release();
        
        self.count = 0;
    }
    
    pub fn get_waiting(self: *const Barrier) u32 {
        return self.count;
    }
};