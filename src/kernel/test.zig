// Test suite for the redesigned kernel
const std = @import("std");

// Import kernel components
const arch = @import("arch.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const process = @import("process.zig");
const interrupts = @import("interrupts.zig");
const syscall = @import("syscall.zig");
const spinlock = @import("spinlock.zig");
const kheap = @import("kheap.zig");
const fs = @import("fs.zig");
const driver = @import("driver.zig");
const timer = @import("timer.zig");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

// Test result
const TestResult = struct {
    passed: bool,
    message: []const u8,
};

// Test case
const TestCase = struct {
    name: []const u8,
    func: *const fn () TestResult,
};

// Test suite
const TestSuite = struct {
    name: []const u8,
    cases: []const TestCase,
    
    pub fn run(self: *const TestSuite) void {
        serial.write("Running test suite: ");
        serial.write(self.name);
        serial.write("\n");
        
        var passed: usize = 0;
        var failed: usize = 0;
        
        for (self.cases) |case| {
            serial.write("  Running test: ");
            serial.write(case.name);
            serial.write("... ");
            
            const result = case.func();
            
            if (result.passed) {
                serial.write("PASSED\n");
                passed += 1;
            } else {
                serial.write("FAILED: ");
                serial.write(result.message);
                serial.write("\n");
                failed += 1;
            }
        }
        
        serial.write("Test suite complete: ");
        serial.write_hex(@as(u64, passed));
        serial.write(" passed, ");
        serial.write_hex(@as(u64, failed));
        serial.write(" failed\n\n");
    }
};

// Test functions
fn test_spinlock() TestResult {
    var lock = spinlock.Spinlock.init();
    
    // Test basic lock/unlock
    lock.acquire();
    if (!lock.is_locked()) {
        return .{ .passed = false, .message = "Lock should be locked after acquire" };
    }
    lock.release();
    if (lock.is_locked()) {
        return .{ .passed = false, .message = "Lock should be unlocked after release" };
    }
    
    // Test recursive locking (should fail)
    lock.acquire();
    var recursive_failed = false;
    if (lock.try_acquire()) {
        recursive_failed = true;
        lock.release();
    }
    lock.release();
    
    if (!recursive_failed) {
        return .{ .passed = false, .message = "Recursive locking should fail" };
    }
    
    return .{ .passed = true, .message = "" };
}

fn test_rw_spinlock() TestResult {
    var lock = spinlock.RwSpinlock.init();
    
    // Test read lock
    lock.acquire_read();
    if (!lock.is_locked()) {
        return .{ .passed = false, .message = "Lock should be locked after acquire_read" };
    }
    
    // Test multiple read locks
    if (!lock.try_acquire_read()) {
        return .{ .passed = false, .message = "Multiple read locks should be allowed" };
    }
    lock.release_read();
    lock.release_read();
    
    // Test write lock
    lock.acquire_write();
    if (!lock.is_locked()) {
        return .{ .passed = false, .message = "Lock should be locked after acquire_write" };
    }
    
    // Test write lock exclusivity
    if (lock.try_acquire_read()) {
        lock.release_read();
        return .{ .passed = false, .message = "Read lock should fail while write lock is held" };
    }
    
    if (lock.try_acquire_write()) {
        lock.release_write();
        return .{ .passed = false, .message = "Write lock should fail while write lock is held" };
    }
    
    lock.release_write();
    
    return .{ .passed = true, .message = "" };
}

fn test_mutex() TestResult {
    var mutex = spinlock.Mutex.init();
    
    // Test basic lock/unlock
    mutex.acquire();
    if (!mutex.is_locked()) {
        return .{ .passed = false, .message = "Mutex should be locked after acquire" };
    }
    mutex.release();
    if (mutex.is_locked()) {
        return .{ .passed = false, .message = "Mutex should be unlocked after release" };
    }
    
    // Test try_acquire
    if (!mutex.try_acquire()) {
        return .{ .passed = false, .message = "try_acquire should succeed on unlocked mutex" };
    }
    
    if (mutex.try_acquire()) {
        mutex.release();
        return .{ .passed = false, .message = "try_acquire should fail on locked mutex" };
    }
    
    mutex.release();
    
    return .{ .passed = true, .message = "" };
}

fn test_semaphore() TestResult {
    var semaphore = spinlock.Semaphore.init(3, 10);
    
    // Test initial value
    if (semaphore.get_value() != 3) {
        return .{ .passed = false, .message = "Semaphore should have initial value of 3" };
    }
    
    // Test wait
    if (!semaphore.try_wait()) {
        return .{ .passed = false, .message = "try_wait should succeed when count > 0" };
    }
    
    if (semaphore.get_value() != 2) {
        return .{ .passed = false, .message = "Semaphore value should be 2 after one wait" };
    }
    
    // Test post
    semaphore.post();
    
    if (semaphore.get_value() != 3) {
        return .{ .passed = false, .message = "Semaphore value should be 3 after post" };
    }
    
    // Test multiple waits
    if (!semaphore.try_wait()) return .{ .passed = false, .message = "try_wait should succeed" };
    if (!semaphore.try_wait()) return .{ .passed = false, .message = "try_wait should succeed" };
    if (!semaphore.try_wait()) return .{ .passed = false, .message = "try_wait should succeed" };
    
    if (semaphore.get_value() != 0) {
        return .{ .passed = false, .message = "Semaphore value should be 0 after three waits" };
    }
    
    if (semaphore.try_wait()) {
        semaphore.post();
        return .{ .passed = false, .message = "try_wait should fail when count = 0" };
    }
    
    // Test multiple posts
    semaphore.post();
    semaphore.post();
    semaphore.post();
    
    if (semaphore.get_value() != 3) {
        return .{ .passed = false, .message = "Semaphore value should be 3 after three posts" };
    }
    
    return .{ .passed = true, .message = "" };
}

fn test_barrier() TestResult {
    var barrier = spinlock.Barrier.init(3);
    
    // Test initial state
    if (barrier.get_waiting() != 0) {
        return .{ .passed = false, .message = "Barrier should have 0 waiting threads initially" };
    }
    
    // Test wait (should block until all threads arrive)
    // This is a simplified test since we can't easily create multiple threads
    // In a real test, we would create multiple threads and have them wait on the barrier
    
    return .{ .passed = true, .message = "" };
}

fn test_pmm() TestResult {
    // Initialize PMM
    const pmm_instance = pmm.init();
    _ = pmm_instance; // Avoid unused variable warning
    
    // This is a simplified test since we can't easily test PMM without a full memory setup
    // In a real test, we would set up a memory map and test allocation/free
    
    return .{ .passed = true, .message = "" };
}

fn test_vmm() TestResult {
    // This is a simplified test since we can't easily test VMM without a full memory setup
    // In a real test, we would create page tables, map pages, etc.
    
    // Test that VMM can be initialized
    _ = vmm.init() catch return .{ .passed = false, .message = "Failed to initialize VMM" };
    
    // Test that we can get the kernel address space
    const addr_space = vmm.get_kernel_address_space();
    if (addr_space == null) {
        return .{ .passed = false, .message = "Failed to get kernel address space" };
    }
    
    return .{ .passed = true, .message = "" };
}

fn test_kheap() TestResult {
    // Initialize heap
    _ = kheap.init() catch return .{ .passed = false, .message = "Failed to initialize heap" };
    
    // Test allocation
    const ptr1 = kheap.alloc(100, 8) catch return .{ .passed = false, .message = "Failed to allocate memory" };
    const ptr2 = kheap.alloc(200, 8) catch return .{ .passed = false, .message = "Failed to allocate memory" };
    
    // Pointers should be different
    if (ptr1 == ptr2) {
        return .{ .passed = false, .message = "Allocated pointers should be different" };
    }
    
    // Test free
    kheap.free(ptr1);
    const ptr3 = kheap.alloc(100, 8) catch return .{ .passed = false, .message = "Failed to allocate memory after free" };
    
    // Should get a valid pointer (not necessarily the same one)
    _ = ptr3; // Mark as used
    
    // Test realloc
    const ptr4 = kheap.realloc(ptr2, 300) catch return .{ .passed = false, .message = "Failed to reallocate memory" };
    
    // Should get a valid pointer
    _ = ptr4; // Mark as used
    
    // Test stats
    const stats = kheap.get_stats();
    if (stats.total_size == 0) {
        return .{ .passed = false, .message = "Total heap size should be > 0" };
    }
    
    return .{ .passed = true, .message = "" };
}

fn test_timer() TestResult {
    // Initialize timer
    _ = timer.init() catch return .{ .passed = false, .message = "Failed to initialize timer" };
    
    // Test that we can get the current time
    const time_ns = timer.get_time_ns();
    const time_ms = timer.get_time_ms();
    const time_s = timer.get_time_s();
    
    // Time should be reasonable
    if (time_ns == 0) {
        return .{ .passed = false, .message = "Time should be > 0" };
    }
    
    // Check time conversions
    if (time_ms != time_ns / 1000000) {
        return .{ .passed = false, .message = "Time conversion from ns to ms is incorrect" };
    }
    
    if (time_s != time_ns / 1000000000) {
        return .{ .passed = false, .message = "Time conversion from ns to s is incorrect" };
    }
    
    // Test sleep (short sleep)
    const start_ms = timer.get_time_ms();
    timer.sleep_ms(10); // Sleep for 10ms
    const end_ms = timer.get_time_ms();
    
    // Should have slept for at least 10ms (with some tolerance)
    if (end_ms - start_ms < 8) {
        return .{ .passed = false, .message = "Sleep duration too short" };
    }
    
    return .{ .passed = true, .message = "" };
}

fn test_interrupts() TestResult {
    // Initialize interrupts
    interrupts.init();
    
    // Test that we can enable/disable interrupts
    const flags = interrupts.save_flags();
    interrupts.disable_interrupts();
    
    // Check that interrupts are disabled
    const current_flags = interrupts.save_flags();
    if (current_flags & arch.RFLAGS.IF != 0) {
        return .{ .passed = false, .message = "Interrupts should be disabled" };
    }
    
    // Restore flags
    interrupts.restore_flags(flags);
    
    return .{ .passed = true, .message = "" };
}

fn test_process() TestResult {
    // Initialize process manager
    process.init();
    
    // This is a simplified test since we can't easily test process manager without a full setup
    // In a real test, we would create processes and test their properties
    
    return .{ .passed = true, .message = "" };
}

fn test_syscall() TestResult {
    // Initialize syscall interface
    syscall.init();
    
    // This is a simplified test since we can't easily test syscalls without user space
    // In a real test, we would create a user space process and make syscalls
    
    return .{ .passed = true, .message = "" };
}

fn test_fs() TestResult {
    // Initialize file system
    _ = fs.init() catch return .{ .passed = false, .message = "Failed to initialize file system" };
    
    // Test that we can look up the root directory
    const root_inode = fs.lookup("/") catch return .{ .passed = false, .message = "Failed to look up root directory" };
    if (root_inode == null) {
        return .{ .passed = false, .message = "Root inode should not be null" };
    }
    
    // Test that we can create a file
    const file_inode = fs.create("/test", .{ .owner_read = true, .owner_write = true }) catch return .{ .passed = false, .message = "Failed to create file" };
    if (file_inode == null) {
        return .{ .passed = false, .message = "File inode should not be null" };
    }
    
    // Test that we can create a directory
    fs.mkdir("/testdir", .{ .owner_read = true, .owner_write = true, .owner_execute = true }) catch return .{ .passed = false, .message = "Failed to create directory" };
    
    return .{ .passed = true, .message = "" };
}

fn test_driver() TestResult {
    // Initialize driver manager
    _ = driver.init() catch return .{ .passed = false, .message = "Failed to initialize driver manager" };
    
    // This is a simplified test since we can't easily test drivers without hardware
    // In a real test, we would create mock devices and drivers
    
    return .{ .passed = true, .message = "" };
}

// Test suites
const sync_test_suite = TestSuite{
    .name = "Synchronization Primitives",
    .cases = &[_]TestCase{
        .{ .name = "Spinlock", .func = test_spinlock },
        .{ .name = "RW Spinlock", .func = test_rw_spinlock },
        .{ .name = "Mutex", .func = test_mutex },
        .{ .name = "Semaphore", .func = test_semaphore },
        .{ .name = "Barrier", .func = test_barrier },
    },
};

const memory_test_suite = TestSuite{
    .name = "Memory Management",
    .cases = &[_]TestCase{
        .{ .name = "PMM", .func = test_pmm },
        .{ .name = "VMM", .func = test_vmm },
        .{ .name = "Kernel Heap", .func = test_kheap },
    },
};

const system_test_suite = TestSuite{
    .name = "System Components",
    .cases = &[_]TestCase{
        .{ .name = "Timer", .func = test_timer },
        .{ .name = "Interrupts", .func = test_interrupts },
        .{ .name = "Process", .func = test_process },
        .{ .name = "Syscall", .func = test_syscall },
        .{ .name = "File System", .func = test_fs },
        .{ .name = "Driver", .func = test_driver },
    },
};

// Run all tests
pub fn run_all_tests() void {
    serial.write("========================================\n");
    serial.write("Running Kernel Test Suite\n");
    serial.write("========================================\n\n");
    
    // Run test suites
    sync_test_suite.run();
    memory_test_suite.run();
    system_test_suite.run();
    
    serial.write("========================================\n");
    serial.write("All tests completed\n");
    serial.write("========================================\n");
}