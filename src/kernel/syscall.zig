// System call interface for user-kernel communication
const std = @import("std");
const arch = @import("arch.zig");
const process = @import("process.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const interrupts = @import("interrupts.zig");

// System call numbers
pub const SyscallNumber = enum(u64) {
    // Process management
    Exit = 0,
    Fork = 1,
    Exec = 2,
    Wait = 3,
    Yield = 4,
    Sleep = 5,
    Kill = 6,
    GetPID = 7,
    GetPPID = 8,
    GetUID = 9,
    GetGID = 10,
    SetUID = 11,
    SetGID = 12,
    
    // Memory management
    Mmap = 20,
    Munmap = 21,
    Mprotect = 22,
    Msync = 23,
    Mlock = 24,
    Munlock = 25,
    Brk = 26,
    Sbrk = 27,
    
    // File system
    Open = 40,
    Close = 41,
    Read = 42,
    Write = 43,
    Seek = 44,
    Tell = 45,
    Stat = 46,
    Fstat = 47,
    Lseek = 48,
    Pread = 49,
    Pwrite = 50,
    Dup = 51,
    Dup2 = 52,
    Pipe = 53,
    Mkfifo = 54,
    Link = 55,
    Unlink = 56,
    Symlink = 57,
    Readlink = 58,
    Chmod = 59,
    Chown = 60,
    Umask = 61,
    Getcwd = 62,
    Chdir = 63,
    Mkdir = 64,
    Rmdir = 65,
    Opendir = 66,
    Readdir = 67,
    Closedir = 68,
    Rewinddir = 69,
    Telldir = 70,
    Seekdir = 71,
    
    // Device I/O
    Ioctl = 80,
    Select = 81,
    Poll = 82,
    EpollCreate = 83,
    EpollCtl = 84,
    EpollWait = 85,
    
    // Signal handling
    Signal = 100,
    Sigaction = 101,
    Sigprocmask = 102,
    Sigpending = 103,
    Sigsuspend = 104,
    Sigwait = 105,
    Killpg = 106,
    
    // Time
    Time = 120,
    Gettimeofday = 121,
    ClockGettime = 122,
    ClockSettime = 123,
    Nanosleep = 124,
    Alarm = 125,
    Setitimer = 126,
    Getitimer = 127,
    
    // Network
    Socket = 140,
    Bind = 141,
    Listen = 142,
    Accept = 143,
    Connect = 144,
    Send = 145,
    Recv = 146,
    Sendto = 147,
    Recvfrom = 148,
    Shutdown = 149,
    Getsockname = 150,
    Getpeername = 151,
    Getsockopt = 152,
    Setsockopt = 153,
    
    // System information
    Uname = 160,
    Sysinfo = 161,
    Getrlimit = 162,
    Setrlimit = 163,
    Getrusage = 164,
    
    // Threading
    ThreadCreate = 180,
    ThreadExit = 181,
    ThreadJoin = 182,
    ThreadYield = 183,
    MutexInit = 184,
    MutexLock = 185,
    MutexUnlock = 186,
    MutexTrylock = 187,
    CondInit = 188,
    CondWait = 189,
    CondSignal = 190,
    CondBroadcast = 191,
    
    // Shared memory
    ShmOpen = 200,
    ShmUnlink = 201,
    ShmGet = 202,
    Shmat = 203,
    Shmdt = 204,
    Shmctl = 205,
    
    // Message queues
    Msgget = 220,
    Msgsnd = 221,
    Msgrcv = 222,
    Msgctl = 223,
    
    // Semaphores
    Semget = 240,
    Semop = 241,
    Semctl = 242,
    
    // Debugging
    DebugBreak = 254,
    DebugLog = 255,
};

// System call result
pub const SyscallResult = union(enum) {
    Success: u64,
    Error: u64,
    Blocked: void,
};

// System call context
pub const SyscallContext = struct {
    number: SyscallNumber,
    args: [6]u64,
    result: SyscallResult,
    process: *process.Process,
};

// System call table
const SyscallHandler = *const fn (context: *SyscallContext) SyscallResult;
var syscall_table: [256]?SyscallHandler = [_]?SyscallHandler{null} ** 256;

// Initialize system call interface
pub fn init() void {
    // Register system call handlers
    register_syscall_handler(.Exit, syscall_exit);
    register_syscall_handler(.Fork, syscall_fork);
    register_syscall_handler(.Exec, syscall_exec);
    register_syscall_handler(.Wait, syscall_wait);
    register_syscall_handler(.Yield, syscall_yield);
    register_syscall_handler(.Sleep, syscall_sleep);
    register_syscall_handler(.Kill, syscall_kill);
    register_syscall_handler(.GetPID, syscall_getpid);
    register_syscall_handler(.GetPPID, syscall_getppid);
    
    register_syscall_handler(.Mmap, syscall_mmap);
    register_syscall_handler(.Munmap, syscall_munmap);
    register_syscall_handler(.Mprotect, syscall_mprotect);
    register_syscall_handler(.Brk, syscall_brk);
    register_syscall_handler(.Sbrk, syscall_sbrk);
    
    register_syscall_handler(.Open, syscall_open);
    register_syscall_handler(.Close, syscall_close);
    register_syscall_handler(.Read, syscall_read);
    register_syscall_handler(.Write, syscall_write);
    register_syscall_handler(.Seek, syscall_seek);
    register_syscall_handler(.Stat, syscall_stat);
    register_syscall_handler(.Fstat, syscall_fstat);
    
    register_syscall_handler(.Signal, syscall_signal);
    register_syscall_handler(.Sigaction, syscall_sigaction);
    register_syscall_handler(.Sigprocmask, syscall_sigprocmask);
    
    register_syscall_handler(.Time, syscall_time);
    register_syscall_handler(.Gettimeofday, syscall_gettimeofday);
    register_syscall_handler(.Nanosleep, syscall_nanosleep);
    
    register_syscall_handler(.DebugLog, syscall_debug_log);
    
    serial.write("syscall: system call interface initialized\n");
}

// Register system call handler
fn register_syscall_handler(number: SyscallNumber, handler: SyscallHandler) void {
    syscall_table[@intFromEnum(number)] = handler;
}

// System call entry point
pub fn handle_syscall(registers: *arch.Registers) void {
    const manager = process.get_manager();
    const current_process = manager.current_process orelse {
        registers.rax = @as(u64, @bitCast(@as(i32, -1)));
        return;
    };
    
    const syscall_num = @as(SyscallNumber, @enumFromInt(registers.rax));
    
    var context = SyscallContext{
        .number = syscall_num,
        .args = .{
            registers.rdi,
            registers.rsi,
            registers.rdx,
            registers.r10,
            registers.r8,
            registers.r9,
        },
        .result = .{ .Error = @as(u64, @bitCast(@as(i64, -1))) },
        .process = current_process,
    };
    
    // Call system call handler
    if (syscall_table[@intFromEnum(syscall_num)]) |handler| {
        context.result = handler(&context);
    } else {
        serial.write("syscall: unknown syscall ");
        serial.write_hex(@as(u64, @intFromEnum(syscall_num)));
        serial.write("\n");
        context.result = .{ .Error = @as(u64, @bitCast(@as(i32, -38))) }; // ENOSYS
    }
    
    // Set return value
    switch (context.result) {
        .Success => |value| registers.rax = value,
        .Error => |error_code| registers.rax = error_code,
        .Blocked => {
            // Process is blocked, schedule another
            manager.schedule();
        },
    }
}

// System call implementations

// Process management syscalls
fn syscall_exit(context: *SyscallContext) SyscallResult {
    const exit_code = @as(i32, @truncate(@as(i64, @bitCast(context.args[0]))));
    context.process.exit_code = exit_code;
    context.process.set_state(.Terminated);
    return .{ .Success = 0 };
}

fn syscall_fork(context_param: *SyscallContext) SyscallResult {
    // TODO: Implement fork
    _ = context_param;
    return .{ .Error = @as(u64, @bitCast(@as(i64, -12))) }; // ENOMEM
}

fn syscall_exec(context_param: *SyscallContext) SyscallResult {
    // TODO: Implement exec
    _ = context_param;
    return .{ .Error = @as(u64, @bitCast(@as(i64, -2))) }; // ENOENT
}

fn syscall_wait(context: *SyscallContext) SyscallResult {
    const pid = @as(u32, @intCast(context.args[0]));
    const manager = process.get_manager();
    
    if (manager.wait_for_child(pid)) |child| {
        return .{ .Success = @as(u64, @bitCast(@as(i64, child.exit_code))) };
    }
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -10))) }; // ECHILD
}

fn syscall_yield(context_param: *SyscallContext) SyscallResult {
    _ = context_param;
    const manager = process.get_manager();
    _ = manager.yield();
    return .{ .Success = 0 };
}

fn syscall_sleep(context: *SyscallContext) SyscallResult {
    const milliseconds = context.args[0];
    const manager = process.get_manager();
    manager.sleep(milliseconds);
    return .{ .Success = 0 };
}

fn syscall_kill(context: *SyscallContext) SyscallResult {
    const pid = @as(u32, @intCast(context.args[0]));
    const signal = @as(process.Signal, @enumFromInt(@as(i32, @truncate(context.args[1]))));
    
    const manager = process.get_manager();
    if (manager.kill_process(pid, signal)) {
        return .{ .Success = 0 };
    }
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -3))) }; // ESRCH
}

fn syscall_getpid(context: *SyscallContext) SyscallResult {
    return .{ .Success = @as(u64, context.process.id) };
}

fn syscall_getppid(context: *SyscallContext) SyscallResult {
    return .{ .Success = @as(u64, context.process.parent_id) };
}

// Memory management syscalls
fn syscall_mmap(context: *SyscallContext) SyscallResult {
    const addr = context.args[0];
    const length = context.args[1];
    const prot = context.args[2];
    const flags = context.args[3];
    const fd = @as(i32, @truncate(@as(i64, @bitCast(context.args[4]))));
    const offset = context.args[5];
    
    // TODO: Implement mmap
    _ = addr;
    _ = length;
    _ = prot;
    _ = flags;
    _ = fd;
    _ = offset;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -12))) }; // ENOMEM
}

fn syscall_munmap(context: *SyscallContext) SyscallResult {
    const addr = context.args[0];
    const length = context.args[1];
    
    // TODO: Implement munmap
    _ = addr;
    _ = length;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -22))) }; // EINVAL
}

fn syscall_mprotect(context: *SyscallContext) SyscallResult {
    const addr = context.args[0];
    const length = context.args[1];
    const prot = context.args[2];
    
    // TODO: Implement mprotect
    _ = addr;
    _ = length;
    _ = prot;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -22))) }; // EINVAL
}

fn syscall_brk(context: *SyscallContext) SyscallResult {
    const addr = context.args[0];
    
    if (addr == 0) {
        // Return current break
        return .{ .Success = context.process.heap_base + context.process.heap_size };
    }
    
    // TODO: Implement brk
    return .{ .Error = @as(u64, @bitCast(@as(i64, -12))) }; // ENOMEM
}

fn syscall_sbrk(context: *SyscallContext) SyscallResult {
    const increment = @as(i64, @bitCast(@as(i32, @truncate(context.args[0]))));
    
    if (increment == 0) {
        // Return current break
        return .{ .Success = context.process.heap_base + context.process.heap_size };
    }
    
    // TODO: Implement sbrk
    return .{ .Error = @as(u64, @bitCast(@as(i64, -12))) }; // ENOMEM
}

// File system syscalls
fn syscall_open(context: *SyscallContext) SyscallResult {
    const path_ptr = context.args[0];
    const flags = @as(i32, @truncate(@as(i64, @bitCast(context.args[1]))));
    const mode = @as(u32, @intCast(context.args[2]));
    
    // TODO: Implement open
    _ = path_ptr;
    _ = flags;
    _ = mode;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -2))) }; // ENOENT
}

fn syscall_close(context: *SyscallContext) SyscallResult {
    const fd = @as(i32, @truncate(@as(i64, @bitCast(context.args[0]))));
    
    // TODO: Implement close
    _ = fd;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -9))) }; // EBADF
}

fn syscall_read(context: *SyscallContext) SyscallResult {
    const fd = @as(i32, @truncate(@as(i64, @bitCast(context.args[0]))));
    const buf_ptr = context.args[1];
    const count = context.args[2];
    
    // TODO: Implement read
    _ = fd;
    _ = buf_ptr;
    _ = count;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -9))) }; // EBADF
}

fn syscall_write(context: *SyscallContext) SyscallResult {
    const fd = @as(i32, @truncate(@as(i64, @bitCast(context.args[0]))));
    const buf_ptr = context.args[1];
    const count = context.args[2];
    
    // Handle stdout/stderr
    if (fd == 1 or fd == 2) {
        const buf = @as([*]const u8, @ptrFromInt(buf_ptr));
        var i: usize = 0;
        while (i < count) : (i += 1) {
            serial.write_byte(buf[i]);
        }
        return .{ .Success = count };
    }
    
    // TODO: Implement write for other file descriptors
    return .{ .Error = @as(u64, @bitCast(@as(i64, -9))) }; // EBADF
}

fn syscall_seek(context: *SyscallContext) SyscallResult {
    const fd = @as(i32, @truncate(@as(i64, @bitCast(context.args[0]))));
    const offset = @as(i64, @bitCast(@as(i32, @truncate(context.args[1]))));
    const whence = @as(i32, @bitCast(@as(i64, @truncate(context.args[2]))));
    
    // TODO: Implement seek
    _ = fd;
    _ = offset;
    _ = whence;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -9))) }; // EBADF
}

fn syscall_stat(context: *SyscallContext) SyscallResult {
    const path_ptr = context.args[0];
    const stat_ptr = context.args[1];
    
    // TODO: Implement stat
    _ = path_ptr;
    _ = stat_ptr;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -2))) }; // ENOENT
}

fn syscall_fstat(context: *SyscallContext) SyscallResult {
    const fd = @as(i32, @truncate(@as(i64, @bitCast(context.args[0]))));
    const stat_ptr = context.args[1];
    
    // TODO: Implement fstat
    _ = fd;
    _ = stat_ptr;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -9))) }; // EBADF
}

// Signal handling syscalls
fn syscall_signal(context: *SyscallContext) SyscallResult {
    const signal = @as(process.Signal, @enumFromInt(@as(i32, @truncate(context.args[0]))));
    const handler = @as(?*const fn (i32) void, @ptrFromInt(context.args[1]));
    
    const action = process.SignalAction{
        .handler = handler,
        .flags = 0,
        .mask = 0,
        .restorer = null,
    };
    
    context.process.set_signal_action(signal, action);
    return .{ .Success = 0 };
}

fn syscall_sigaction(context: *SyscallContext) SyscallResult {
    const signal = @as(process.Signal, @enumFromInt(@as(i32, @truncate(context.args[0]))));
    const act_ptr = context.args[1];
    const oldact_ptr = context.args[2];
    
    if (act_ptr != 0) {
        const act = @as(*const process.SignalAction, @ptrFromInt(act_ptr));
        context.process.set_signal_action(signal, act.*);
    }
    
    if (oldact_ptr != 0) {
        const oldact = @as(*process.SignalAction, @ptrFromInt(oldact_ptr));
        oldact.* = context.process.get_signal_action(signal);
    }
    
    return .{ .Success = 0 };
}

fn syscall_sigprocmask(context: *SyscallContext) SyscallResult {
    const how = @as(i32, @truncate(@as(i64, @bitCast(context.args[0]))));
    const set_ptr = context.args[1];
    const oldset_ptr = context.args[2];
    
    if (oldset_ptr != 0) {
        const oldset = @as(*u64, @ptrFromInt(oldset_ptr));
        oldset.* = context.process.signal_mask;
    }
    
    if (set_ptr != 0) {
        const set = @as(*const u64, @ptrFromInt(set_ptr));
        switch (how) {
            0 => { // SIG_BLOCK
                context.process.signal_mask |= set.*;
            },
            1 => { // SIG_UNBLOCK
                context.process.signal_mask &= ~set.*;
            },
            2 => { // SIG_SETMASK
                context.process.signal_mask = set.*;
            },
            else => {
                return .{ .Error = @as(u64, @bitCast(@as(i64, -22))) }; // EINVAL
            }
        }
    }
    
    return .{ .Success = 0 };
}

// Time syscalls
fn syscall_time(context_param: *SyscallContext) SyscallResult {
    // TODO: Implement time
    _ = context_param;
    return .{ .Success = 0 }; // Return 0 for now
}

fn syscall_gettimeofday(context: *SyscallContext) SyscallResult {
    const tv_ptr = context.args[0];
    const tz_ptr = context.args[1];
    
    // TODO: Implement gettimeofday
    _ = tv_ptr;
    _ = tz_ptr;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -1))) }; // EPERM
}

fn syscall_nanosleep(context: *SyscallContext) SyscallResult {
    const req_ptr = context.args[0];
    const rem_ptr = context.args[1];
    
    // TODO: Implement nanosleep
    _ = req_ptr;
    _ = rem_ptr;
    
    return .{ .Error = @as(u64, @bitCast(@as(i64, -4))) }; // EINTR
}

// Debugging syscalls
fn syscall_debug_log(context: *SyscallContext) SyscallResult {
    const str_ptr = context.args[0];
    const len = context.args[1];
    
    const str = @as([*]const u8, @ptrFromInt(str_ptr));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        serial.write_byte(str[i]);
    }
    
    return .{ .Success = 0 };
}

// System call entry point in assembly
export fn syscall_entry() callconv(.Naked) void {
    asm volatile (
        \\push %rcx
        \\push %r11
        \\push %rsp
        \\cld
        \\call syscall_handler
        \\pop %rsp
        \\pop %r11
        \\pop %rcx
        \\sysretq
    );
}

// System call handler (called from assembly)
export fn syscall_handler() void {
    // This will be called by the assembly entry point
    // The actual handling is done by handle_syscall in process.zig
    // TODO: Implement syscall handler
    _ = undefined; // Suppress unused function warning
}