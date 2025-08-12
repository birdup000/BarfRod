// Process management system with scheduler and context switching
const std = @import("std");
const arch = @import("arch.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const spinlock = @import("spinlock.zig");

// Process states
pub const ProcessState = enum(u8) {
    Created,
    Ready,
    Running,
    Blocked,
    Terminated,
    Zombie,
};

// Process priority levels
pub const ProcessPriority = enum(u8) {
    Idle = 0,
    Low = 1,
    Normal = 2,
    High = 3,
    Realtime = 4,
};

// Process flags
pub const ProcessFlags = packed struct {
    kernel: u1,        // Kernel process
    user: u1,          // User process
    system: u1,        // System process
    fixed_priority: u1, // Fixed priority (no dynamic adjustment)
    round_robin: u1,   // Use round-robin scheduling
    realtime: u1,      // Real-time process
    reserved: u2,
};

// File descriptor
pub const FileDescriptor = struct {
    flags: u32,
    offset: u64,
    file: ?*anyopaque, // File structure
    next: ?*FileDescriptor,
};

// Signal handling
pub const Signal = enum(i32) {
    SIGHUP = 1,
    SIGINT = 2,
    SIGQUIT = 3,
    SIGILL = 4,
    SIGTRAP = 5,
    SIGABRT = 6,
    SIGBUS = 7,
    SIGFPE = 8,
    SIGKILL = 9,
    SIGUSR1 = 10,
    SIGSEGV = 11,
    SIGUSR2 = 12,
    SIGPIPE = 13,
    SIGALRM = 14,
    SIGTERM = 15,
    SIGSTKFLT = 16,
    SIGCHLD = 17,
    SIGCONT = 18,
    SIGSTOP = 19,
    SIGTSTP = 20,
    SIGTTIN = 21,
    SIGTTOU = 22,
    SIGURG = 23,
    SIGXCPU = 24,
    SIGXFSZ = 25,
    SIGVTALRM = 26,
    SIGPROF = 27,
    SIGWINCH = 28,
    SIGIO = 29,
    SIGPWR = 30,
    SIGSYS = 31,
};

pub const SignalAction = struct {
    handler: ?*const fn (i32) void,
    flags: u32,
    mask: u64,
    restorer: ?*const fn () void,
};

// Process control block
pub const Process = struct {
    id: u32,
    parent_id: u32,
    state: ProcessState,
    priority: ProcessPriority,
    flags: ProcessFlags,
    exit_code: i32,
    signal_mask: u64,
    signal_actions: [32]SignalAction,
    pending_signals: u64,
    
    // Memory management
    address_space: ?*vmm.AddressSpace,
    stack_base: u64,
    stack_size: u64,
    heap_base: u64,
    heap_size: u64,
    
    // File management
    file_descriptors: ?*FileDescriptor,
    working_directory: [256]u8,
    
    // Scheduling
    time_slice: u32,
    time_used: u32,
    quantum: u32,
    static_priority: u8,
    dynamic_priority: u8,
    
    // Context
    context: arch.Registers,
    kernel_stack: u64,
    
    // List management
    next: ?*Process,
    prev: ?*Process,
    children: ?*Process,
    siblings: ?*Process,
    
    // Wait queue
    wait_queue: ?*Process,
    wait_reason: u32,
    
    // Statistics
    start_time: u64,
    cpu_time: u64,
    syscalls: u64,
    context_switches: u64,
    page_faults: u64,
    
    pub fn init(id: u32, parent_id: u32, flags: ProcessFlags) ?*Process {
        const process = pmm.slab_alloc(Process) orelse return null;
        process.* = .{
            .id = id,
            .parent_id = parent_id,
            .state = .Created,
            .priority = .Normal,
            .flags = flags,
            .exit_code = 0,
            .signal_mask = 0,
            .signal_actions = undefined, // Initialize below
            .pending_signals = 0,
            .address_space = null,
            .stack_base = 0,
            .stack_size = 0,
            .heap_base = 0,
            .heap_size = 0,
            .file_descriptors = null,
            .working_directory = undefined,
            .time_slice = 10, // Default time slice
            .time_used = 0,
            .quantum = 10,
            .static_priority = 2,
            .dynamic_priority = 2,
            .context = undefined,
            .kernel_stack = 0,
            .next = null,
            .prev = null,
            .children = null,
            .siblings = null,
            .wait_queue = null,
            .wait_reason = 0,
            .start_time = 0,
            .cpu_time = 0,
            .syscalls = 0,
            .context_switches = 0,
            .page_faults = 0,
        };
        
        // Initialize signal actions to default
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            process.signal_actions[i] = .{
                .handler = null,
                .flags = 0,
                .mask = 0,
                .restorer = null,
            };
        }
        
        return process;
    }
    
    pub fn destroy(self: *Process) void {
        // Free address space
        if (self.address_space) |space| {
            _ = space;
            // space.destroy();
        }
        
        // Free file descriptors
        var fd = self.file_descriptors;
        while (fd) |current| {
            const next = current.next;
            pmm.slab_free(current, FileDescriptor);
            fd = next;
        }
        
        // Free process structure
        pmm.slab_free(self, Process);
    }
    
    pub fn add_child(self: *Process, child: *Process) void {
        child.siblings = self.children;
        self.children = child;
    }
    
    pub fn remove_child(self: *Process, child: *Process) void {
        var current = self.children;
        var prev: ?*Process = null;
        
        while (current) |c| {
            if (c == child) {
                if (prev) |p| {
                    p.siblings = c.siblings;
                } else {
                    self.children = c.siblings;
                }
                break;
            }
            prev = c;
            current = c.siblings;
        }
    }
    
    pub fn find_child(self: *Process, id: u32) ?*Process {
        var child = self.children;
        while (child) |c| {
            if (c.id == id) {
                return c;
            }
            child = c.siblings;
        }
        return null;
    }
    
    pub fn add_file_descriptor(self: *Process, fd: *FileDescriptor) void {
        fd.next = self.file_descriptors;
        self.file_descriptors = fd;
    }
    
    pub fn get_file_descriptor(self: *Process, fd_num: u32) ?*FileDescriptor {
        var fd = self.file_descriptors;
        var count: u32 = 0;
        
        while (fd) |current| {
            if (count == fd_num) {
                return current;
            }
            fd = current.next;
            count += 1;
        }
        
        return null;
    }
    
    pub fn set_signal_action(self: *Process, signal: Signal, action: SignalAction) void {
        const sig_num = @as(usize, @intCast(@intFromEnum(signal)));
        if (sig_num > 0 and sig_num <= 32) {
            self.signal_actions[sig_num - 1] = action;
        }
    }
    
    pub fn get_signal_action(self: *Process, signal: Signal) SignalAction {
        const sig_num = @as(usize, @intCast(@intFromEnum(signal)));
        if (sig_num > 0 and sig_num <= 32) {
            return self.signal_actions[sig_num - 1];
        }
        return .{
            .handler = null,
            .flags = 0,
            .mask = 0,
            .restorer = null,
        };
    }
    
    pub fn send_signal(self: *Process, signal: Signal) void {
        const sig_num = @as(u6, @intCast(@intFromEnum(signal)));
        if (sig_num > 0 and sig_num <= 32) {
            self.pending_signals |= @as(u64, 1) << (sig_num - 1);
        }
    }
    
    pub fn has_pending_signal(self: *Process) bool {
        return (self.pending_signals & ~self.signal_mask) != 0;
    }
    
    pub fn get_next_signal(self: *Process) ?Signal {
        const pending = self.pending_signals & ~self.signal_mask;
        if (pending == 0) return null;
        
        const sig_num = @ctz(pending) + 1;
        self.pending_signals &= ~(@as(u64, 1) << (sig_num - 1));
        
        return @as(Signal, @enumFromInt(sig_num));
    }
    
    pub fn set_state(self: *Process, state: ProcessState) void {
        self.state = state;
    }
    
    pub fn set_priority(self: *Process, priority: ProcessPriority) void {
        self.priority = priority;
        self.static_priority = @intFromEnum(priority);
        self.dynamic_priority = self.static_priority;
    }
    
    pub fn adjust_priority(self: *Process) void {
        // Simple priority adjustment based on CPU usage
        if (self.flags.fixed_priority == 0) {
            const cpu_usage = if (self.time_used > 0) 
                @as(f32, @floatFromInt(self.cpu_time)) / @as(f32, @floatFromInt(self.time_used))
            else 0;
            
            if (cpu_usage > 0.8) {
                // High CPU usage, lower priority
                if (self.dynamic_priority > 0) self.dynamic_priority -= 1;
            } else if (cpu_usage < 0.2) {
                // Low CPU usage, raise priority
                if (self.dynamic_priority < 4) self.dynamic_priority += 1;
            }
        }
    }
};

// Process manager
pub const ProcessManager = struct {
    current_process: ?*Process,
    idle_process: ?*Process,
    init_process: ?*Process,
    process_list: ?*Process,
    ready_queue: [5]?*Process, // One queue per priority level
    lock: spinlock.Spinlock,
    next_pid: u32,
    
    pub fn init() ProcessManager {
        return .{
            .current_process = null,
            .idle_process = null,
            .init_process = null,
            .process_list = null,
            .ready_queue = [_]?*Process{null} ** 5,
            .lock = spinlock.Spinlock.init(),
            .next_pid = 1,
        };
    }
    
    pub fn create_process(self: *ProcessManager, parent_id: u32, flags: ProcessFlags, entry: u64, stack: u64) !*Process {
        self.lock.acquire();
        defer self.lock.release();
        
        const pid = self.next_pid;
        self.next_pid += 1;
        
        const process = Process.init(pid, parent_id, flags) orelse return error.OutOfMemory;
        
        // Set up context
        process.context = .{
            .r15 = 0,
            .r14 = 0,
            .r13 = 0,
            .r12 = 0,
            .r11 = 0,
            .r10 = 0,
            .r9 = 0,
            .r8 = 0,
            .rbp = stack,
            .rdi = 0,
            .rsi = 0,
            .rdx = 0,
            .rcx = 0,
            .rbx = 0,
            .rax = 0,
            .vector = 0,
            .error_code = 0,
            .rip = entry,
            .cs = if (flags.user == 1) 0x23 else 0x08, // User or kernel code segment
            .rflags = 0x202, // IF flag set
            .rsp = stack,
            .ss = if (flags.user == 1) 0x1B else 0x10, // User or kernel stack segment
        };
        
        // Allocate kernel stack
        const kernel_stack_phys = pmm.alloc_pages(4) orelse {
            process.destroy();
            return error.OutOfMemory;
        };
        process.kernel_stack = arch.MEMORY_LAYOUT.KERNEL_VIRT_BASE + kernel_stack_phys;
        
        // Add to process list
        process.next = self.process_list;
        if (self.process_list) |head| {
            head.prev = process;
        }
        self.process_list = process;
        
        // Add to parent's children
        if (parent_id != 0) {
            var parent = self.process_list;
            while (parent) |p| {
                if (p.id == parent_id) {
                    p.add_child(process);
                    break;
                }
                parent = p.next;
            }
        }
        
        // Set state to ready
        process.set_state(.Ready);
        self.add_to_ready_queue(process);
        
        serial.write("process: created process ");
        serial.write_hex(@as(u64, pid));
        serial.write("\n");
        
        return process;
    }
    
    pub fn destroy_process(self: *ProcessManager, process: *Process) void {
        self.lock.acquire();
        defer self.lock.release();
        
        // Remove from process list
        if (process.prev) |prev| {
            prev.next = process.next;
        } else {
            self.process_list = process.next;
        }
        
        if (process.next) |next| {
            next.prev = process.prev;
        }
        
        // Remove from parent's children
        if (process.parent_id != 0) {
            var parent = self.process_list;
            while (parent) |p| {
                if (p.id == process.parent_id) {
                    p.remove_child(process);
                    break;
                }
                parent = p.next;
            }
        }
        
        // Remove from ready queue
        self.remove_from_ready_queue(process);
        
        // Destroy the process
        process.destroy();
        
        serial.write("process: destroyed process ");
        serial.write_hex(@as(u64, process.id));
        serial.write("\n");
    }
    
    pub fn find_process(self: *ProcessManager, pid: u32) ?*Process {
        self.lock.acquire();
        defer self.lock.release();
        
        var process = self.process_list;
        while (process) |p| {
            if (p.id == pid) {
                return p;
            }
            process = p.next;
        }
        
        return null;
    }
    
    pub fn add_to_ready_queue(self: *ProcessManager, process: *Process) void {
        const priority = @intFromEnum(process.priority);
        process.next = self.ready_queue[priority];
        if (self.ready_queue[priority]) |head| {
            head.prev = process;
        }
        self.ready_queue[priority] = process;
        process.prev = null;
    }
    
    pub fn remove_from_ready_queue(self: *ProcessManager, process: *Process) void {
        const priority = @intFromEnum(process.priority);
        
        if (process.prev) |prev| {
            prev.next = process.next;
        } else {
            self.ready_queue[priority] = process.next;
        }
        
        if (process.next) |next| {
            next.prev = process.prev;
        }
        
        process.next = null;
        process.prev = null;
    }
    
    pub fn get_next_process(self: *ProcessManager) ?*Process {
        // Find highest priority ready process
        var priority: i32 = 4;
        while (priority >= 0) : (priority -= 1) {
            if (self.ready_queue[@as(usize, @intCast(priority))]) |process| {
                // Remove from ready queue
                self.ready_queue[@as(usize, @intCast(priority))] = process.next;
                if (process.next) |next| {
                    next.prev = null;
                }
                
                return process;
            }
        }
        
        // No ready processes, return idle process
        return self.idle_process;
    }
    
    pub fn schedule(self: *ProcessManager) void {
        self.lock.acquire();
        defer self.lock.release();
        
        const current = self.current_process;
        const next = self.get_next_process() orelse return;
        
        if (current == next) return;
        
        // Save current process state
        if (current) |curr| {
            curr.context_switches += 1;
            curr.time_used += 1;
            curr.adjust_priority();
            
            if (curr.state == .Running) {
                curr.set_state(.Ready);
                self.add_to_ready_queue(curr);
            }
        }
        
        // Switch to next process
        self.current_process = next;
        next.set_state(.Running);
        next.time_used = 0;
        
        // Switch address space
        if (next.address_space) |space| {
            _ = space;
            // vmm.get_instance().?.switch_address_space(space);
        }
        
        // Context switch will be handled by the assembly wrapper
    }
    
    pub fn yield(self: *ProcessManager) void {
        self.schedule();
    }
    
    pub fn sleep(self: *ProcessManager, milliseconds: u64) void {
        _ = milliseconds;
        // TODO: Implement sleep with timer
        self.yield();
    }
    
    pub fn wait_for_child(self: *ProcessManager, child_id: u32) ?*Process {
        _ = self;
        _ = child_id;
        // TODO: Implement wait for child
        return null;
    }
    
    pub fn send_signal_to_process(self: *ProcessManager, pid: u32, signal: Signal) bool {
        self.lock.acquire();
        defer self.lock.release();
        
        const process = self.find_process(pid) orelse return false;
        process.send_signal(signal);
        
        // If process is sleeping, wake it up
        if (process.state == .Blocked) {
            process.set_state(.Ready);
            self.add_to_ready_queue(process);
        }
        
        return true;
    }
    
    pub fn kill_process(self: *ProcessManager, pid: u32, signal: Signal) bool {
        return self.send_signal_to_process(pid, signal);
    }
    
    pub fn get_process_stats(self: *ProcessManager, pid: u32) ?struct {
        id: u32,
        state: ProcessState,
        priority: ProcessPriority,
        cpu_time: u64,
        memory_usage: u64,
    } {
        self.lock.acquire();
        defer self.lock.release();
        
        const process = self.find_process(pid) orelse return null;
        
        const memory_usage: u64 = 0;
        if (process.address_space) |space| {
            _ = space;
            // TODO: Calculate memory usage from address space
        }
        
        return .{
            .id = process.id,
            .state = process.state,
            .priority = process.priority,
            .cpu_time = process.cpu_time,
            .memory_usage = memory_usage,
        };
    }
};

// Global process manager instance
var process_manager: ProcessManager = undefined;

pub fn init() void {
    process_manager = ProcessManager.init();
    
    // Create idle process
    const idle_process = process_manager.create_process(0, .{ .kernel = 1, .user = 0, .system = 1, .fixed_priority = 0, .round_robin = 0, .realtime = 0, .reserved = 0 }, 0, 0) catch undefined;
    idle_process.set_priority(.Idle);
    process_manager.idle_process = idle_process;
    
    // Create init process
    const init_process = process_manager.create_process(0, .{ .kernel = 1, .user = 0, .system = 1, .fixed_priority = 0, .round_robin = 0, .realtime = 0, .reserved = 0 }, 0, 0) catch undefined;
    init_process.set_priority(.High);
    process_manager.init_process = init_process;
    
    // Set current process to init
    process_manager.current_process = init_process;
    
    serial.write("process: process manager initialized\n");
}

pub fn get_manager() *ProcessManager {
    return &process_manager;
}

// Assembly context switch function
extern fn context_switch(old_context: *arch.Registers, new_context: *arch.Registers) void;

// Timer interrupt handler
pub fn timer_interrupt() void {
    const manager = get_manager();
    manager.schedule();
}

// System call handler
pub fn syscall_handler(registers: *arch.Registers) void {
    const manager = get_manager();
    if (manager.current_process) |process| {
        process.syscalls += 1;
        
        // Handle system call
        const syscall_num = @as(u64, @bitCast(registers.rax));
        switch (syscall_num) {
            0 => { // exit
                const exit_code = @as(i32, @truncate(@as(i64, @bitCast(registers.rdi))));
                process.exit_code = exit_code;
                process.set_state(.Terminated);
                manager.schedule();
            },
            1 => { // fork
                // TODO: Implement fork
                registers.rax = 0; // Return error for now
            },
            2 => { // exec
                // TODO: Implement exec
                registers.rax = 0; // Return error for now
            },
            3 => { // wait
                // TODO: Implement wait
                registers.rax = 0; // Return error for now
            },
            4 => { // yield
                manager.yield();
            },
            5 => { // sleep
                const milliseconds = registers.rdi;
                manager.sleep(milliseconds);
            },
            6 => { // kill
                const pid = @as(u32, @truncate(registers.rdi));
                const signal = @as(Signal, @enumFromInt(registers.rsi));
                const result = if (manager.kill_process(pid, signal)) @as(u64, 0) else @as(u64, 1);
                registers.rax = result;
            },
            else => {
                // Unknown system call
                registers.rax = @as(u64, @bitCast(@as(i64, -1)));
            }
        }
    }
}