// File system interface for the redesigned kernel
const std = @import("std");
const arch = @import("arch.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const process = @import("process.zig");
const syscall = @import("syscall.zig");
const spinlock = @import("spinlock.zig");
const kheap = @import("kheap.zig");

// File system types
pub const FileSystemType = enum {
    FAT32,
    EXT2,
    EXT3,
    EXT4,
    TMPFS,
    PROCFS,
    DEVFS,
};

// File types
pub const FileType = enum {
    Regular,
    Directory,
    CharacterDevice,
    BlockDevice,
    SymbolicLink,
    Socket,
    FIFO,
};

// File permissions
pub const FileMode = packed struct(u16) {
    owner_read: bool = false,
    owner_write: bool = false,
    owner_execute: bool = false,
    group_read: bool = false,
    group_write: bool = false,
    group_execute: bool = false,
    other_read: bool = false,
    other_write: bool = false,
    other_execute: bool = false,
    set_uid: bool = false,
    set_gid: bool = false,
    sticky: bool = false,
    reserved: u4 = 0,  // Padding to fill the 16 bits

    pub fn toU16(self: FileMode) u16 {
        return @as(u16, @bitCast(self));
    }
};

// File status
pub const FileStat = struct {
    device_id: u64,
    inode: u64,
    mode: FileMode,
    hard_links: u32,
    uid: u32,
    gid: u32,
    size: u64,
    block_size: u32,
    blocks: u64,
    atime: u64, // Access time
    mtime: u64, // Modification time
    ctime: u64, // Creation time
};

// Directory entry
pub const DirEntry = struct {
    inode: u64,
    file_type: FileType,
    name: []const u8,
};

// File operations
pub const FileOperations = struct {
    open: ?*const fn (*File, u32) anyerror!void = null,
    close: ?*const fn (*File) anyerror!void = null,
    read: ?*const fn (*File, []u8) anyerror!usize = null,
    write: ?*const fn (*File, []const u8) anyerror!usize = null,
    seek: ?*const fn (*File, i64, u8) anyerror!i64 = null,
    ioctl: ?*const fn (*File, u64, usize) anyerror!usize = null,
    mmap: ?*const fn (*File, usize, usize, u32) anyerror!*u8 = null,
    sync: ?*const fn (*File) anyerror!void = null,
};

// Inode operations
pub const InodeOperations = struct {
    lookup: ?*const fn (*Inode, []const u8) anyerror!?*Inode = null,
    create: ?*const fn (*Inode, []const u8, FileMode) anyerror!?*Inode = null,
    link: ?*const fn (*Inode, *Inode, []const u8) anyerror!void = null,
    unlink: ?*const fn (*Inode, []const u8) anyerror!void = null,
    symlink: ?*const fn (*Inode, []const u8, []const u8) anyerror!void = null,
    mkdir: ?*const fn (*Inode, []const u8, FileMode) anyerror!void = null,
    rmdir: ?*const fn (*Inode, []const u8) anyerror!void = null,
    rename: ?*const fn (*Inode, []const u8, *Inode, []const u8) anyerror!void = null,
    readlink: ?*const fn (*Inode, []u8) anyerror!usize = null,
    getattr: ?*const fn (*Inode, *FileStat) anyerror!void = null,
    setattr: ?*const fn (*Inode, *const FileStat) anyerror!void = null,
    truncate: ?*const fn (*Inode, u64) anyerror!void = null,
};

// Superblock operations
pub const SuperblockOperations = struct {
    alloc_inode: ?*const fn (*Superblock) anyerror!?*Inode = null,
    free_inode: ?*const fn (*Superblock, *Inode) anyerror!void = null,
    write_inode: ?*const fn (*Superblock, *Inode) anyerror!void = null,
    read_inode: ?*const fn (*Superblock, u64) anyerror!?*Inode = null,
    statfs: ?*const fn (*Superblock, *FileSystemStats) anyerror!void = null,
    remount: ?*const fn (*Superblock, u32) anyerror!void = null,
    sync: ?*const fn (*Superblock) anyerror!void = null,
};

// File system statistics
pub const FileSystemStats = struct {
    total_blocks: u64,
    free_blocks: u64,
    total_inodes: u64,
    free_inodes: u64,
    block_size: u32,
    max_filename_length: u32,
};

// Superblock
pub const Superblock = struct {
    fs_type: FileSystemType,
    device_id: u64,
    block_size: u32,
    total_blocks: u64,
    free_blocks: u64,
    total_inodes: u64,
    free_inodes: u64,
    magic: u32,
    state: u32,
    ops: *const SuperblockOperations,
    private_data: ?*anyopaque = null,
    lock: spinlock.RwSpinlock,
    
    pub fn init(fs_type: FileSystemType, device_id: u64, ops: *const SuperblockOperations) Superblock {
        return .{
            .fs_type = fs_type,
            .device_id = device_id,
            .block_size = 4096,
            .total_blocks = 0,
            .free_blocks = 0,
            .total_inodes = 0,
            .free_inodes = 0,
            .magic = 0,
            .state = 0,
            .ops = ops,
            .private_data = null,
            .lock = spinlock.RwSpinlock.init(),
        };
    }
    
    pub fn read_inode(self: *Superblock, ino: u64) anyerror!?*Inode {
        if (self.ops.read_inode) |read_inode_op| {
            return read_inode_op(self, ino);
        }
        return error.NotSupported;
    }
    
    pub fn write_inode(self: *Superblock, inode: *Inode) anyerror!void {
        if (self.ops.write_inode) |write_inode_op| {
            return write_inode_op(self, inode);
        }
        return error.NotSupported;
    }
    
    pub fn alloc_inode(self: *Superblock) anyerror!?*Inode {
        if (self.ops.alloc_inode) |alloc_inode_op| {
            return alloc_inode_op(self);
        }
        return error.NotSupported;
    }
    
    pub fn free_inode(self: *Superblock, inode: *Inode) anyerror!void {
        if (self.ops.free_inode) |free_inode_op| {
            return free_inode_op(self, inode);
        }
        return error.NotSupported;
    }
    
    pub fn statfs(self: *Superblock, stats: *FileSystemStats) anyerror!void {
        if (self.ops.statfs) |statfs_op| {
            return statfs_op(self, stats);
        }
        return error.NotSupported;
    }
    
    pub fn sync(self: *Superblock) anyerror!void {
        if (self.ops.sync) |sync_op| {
            return sync_op(self);
        }
        return error.NotSupported;
    }
};

// Inode
pub const Inode = struct {
    ino: u64,
    mode: FileMode,
    uid: u32,
    gid: u32,
    size: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    links: u32,
    blocks: u64,
    file_type: FileType,
    ops: *const InodeOperations,
    superblock: *Superblock,
    private_data: ?*anyopaque = null,
    lock: spinlock.RwSpinlock,
    
    pub fn init(ino: u64, file_type: FileType, mode: FileMode, ops: *const InodeOperations, superblock: *Superblock) Inode {
        return .{
            .ino = ino,
            .mode = mode,
            .uid = 0,
            .gid = 0,
            .size = 0,
            .atime = 0,
            .mtime = 0,
            .ctime = 0,
            .links = 0,
            .blocks = 0,
            .file_type = file_type,
            .ops = ops,
            .superblock = superblock,
            .private_data = null,
            .lock = spinlock.RwSpinlock.init(),
        };
    }
    
    pub fn lookup(self: *Inode, name: []const u8) anyerror!?*Inode {
        if (self.ops.lookup) |lookup_op| {
            return lookup_op(self, name);
        }
        return error.NotSupported;
    }
    
    pub fn create(self: *Inode, name: []const u8, mode: FileMode) anyerror!?*Inode {
        if (self.ops.create) |create_op| {
            return create_op(self, name, mode);
        }
        return error.NotSupported;
    }
    
    pub fn mkdir(self: *Inode, name: []const u8, mode: FileMode) anyerror!void {
        if (self.ops.mkdir) |mkdir_op| {
            return mkdir_op(self, name, mode);
        }
        return error.NotSupported;
    }
    
    pub fn getattr(self: *Inode, stat: *FileStat) anyerror!void {
        if (self.ops.getattr) |getattr_op| {
            return getattr_op(self, stat);
        }
        return error.NotSupported;
    }
    
    pub fn setattr(self: *Inode, stat: *const FileStat) anyerror!void {
        if (self.ops.setattr) |setattr_op| {
            return setattr_op(self, stat);
        }
        return error.NotSupported;
    }
    
    pub fn truncate(self: *Inode, size: u64) anyerror!void {
        if (self.ops.truncate) |truncate_op| {
            return truncate_op(self, size);
        }
        return error.NotSupported;
    }
};

// File descriptor
pub const File = struct {
    inode: *Inode,
    pos: u64,
    flags: u32,
    ops: *const FileOperations,
    private_data: ?*anyopaque = null,
    lock: spinlock.RwSpinlock,
    
    pub fn init(inode: *Inode, flags: u32, ops: *const FileOperations) File {
        return .{
            .inode = inode,
            .pos = 0,
            .flags = flags,
            .ops = ops,
            .private_data = null,
            .lock = spinlock.RwSpinlock.init(),
        };
    }
    
    pub fn read(self: *File, buf: []u8) anyerror!usize {
        if (self.ops.read) |read_op| {
            return read_op(self, buf);
        }
        return error.NotSupported;
    }
    
    pub fn write(self: *File, buf: []const u8) anyerror!usize {
        if (self.ops.write) |write_op| {
            return write_op(self, buf);
        }
        return error.NotSupported;
    }
    
    pub fn seek(self: *File, offset: i64, whence: u8) anyerror!i64 {
        if (self.ops.seek) |seek_op| {
            return seek_op(self, offset, whence);
        }
        return error.NotSupported;
    }
    
    pub fn ioctl(self: *File, cmd: u64, arg: usize) anyerror!usize {
        if (self.ops.ioctl) |ioctl_op| {
            return ioctl_op(self, cmd, arg);
        }
        return error.NotSupported;
    }
    
    pub fn mmap(self: *File, addr: usize, length: usize, prot: u32) anyerror!*u8 {
        if (self.ops.mmap) |mmap_op| {
            return mmap_op(self, addr, length, prot);
        }
        return error.NotSupported;
    }
    
    pub fn sync(self: *File) anyerror!void {
        if (self.ops.sync) |sync_op| {
            return sync_op(self);
        }
        return error.NotSupported;
    }
    
    pub fn open(self: *File, flags: u32) anyerror!void {
        if (self.ops.open) |open_op| {
            return open_op(self, flags);
        }
    }
    
    pub fn close(self: *File) anyerror!void {
        if (self.ops.close) |close_op| {
            return close_op(self);
        }
    }
};

// Mount point
pub const MountPoint = struct {
    device_id: u64,
    mount_point: []const u8,
    superblock: *Superblock,
    parent: ?*MountPoint = null,
    children: ?*MountPoint = null,
    next: ?*MountPoint = null,
    flags: u32,
    lock: spinlock.RwSpinlock,
};

// Virtual file system
pub const VirtualFileSystem = struct {
    root_fs: ?*Superblock = null,
    mount_points: ?*MountPoint = null,
    lock: spinlock.RwSpinlock,
    
    pub fn init() VirtualFileSystem {
        return .{
            .root_fs = null,
            .mount_points = null,
            .lock = spinlock.RwSpinlock.init(),
        };
    }
    
    pub fn mount(self: *VirtualFileSystem, device_id: u64, path: []const u8, fs_type: FileSystemType, flags: u32) anyerror!void {
        // Lock the VFS
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Create superblock for the file system
        const superblock = try self.create_superblock(fs_type, device_id);
        
        // Create mount point
        const mount_point = try kheap.alloc(@sizeOf(MountPoint), 8);
        const mp = @as(*MountPoint, @alignCast(@ptrCast(mount_point)));
        mp.* = MountPoint{
            .device_id = device_id,
            .mount_point = try self.duplicate_string(path),
            .superblock = superblock,
            .parent = null,
            .children = null,
            .next = null,
            .flags = flags,
            .lock = spinlock.RwSpinlock.init(),
        };
        
        // Add to mount points list
        if (self.mount_points == null) {
            self.mount_points = mp;
        } else {
            var current = self.mount_points;
            while (current.?.next != null) {
                current = current.?.next;
            }
            current.?.next = mp;
        }
        
        // If this is the root file system
        if (std.mem.eql(u8, path, "/")) {
            self.root_fs = superblock;
        }
    }
    
    pub fn umount(self: *VirtualFileSystem, path: []const u8) anyerror!void {
        // Lock the VFS
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Find mount point
        var prev: ?*MountPoint = null;
        var current = self.mount_points;
        
        while (current != null) {
            if (std.mem.eql(u8, current.?.mount_point, path)) {
                // Remove from list
                if (prev != null) {
                    prev.?.next = current.?.next;
                } else {
                    self.mount_points = current.?.next;
                }
                
                // If this was the root file system
                if (self.root_fs == current.?.superblock) {
                    self.root_fs = null;
                }
                
                // Free mount point
                kheap.free(current.?.mount_point.ptr);
                kheap.free(current);
                
                return;
            }
            prev = current;
            current = current.?.next;
        }
        
        return error.NoSuchFileOrDirectory;
    }
    
    pub fn lookup(self: *VirtualFileSystem, path: []const u8) anyerror!?*Inode {
        // Lock the VFS for reading
        self.lock.acquire_read();
        defer self.lock.release_read();
        
        // Find the mount point for this path
        const mount_point = self.find_mount_point(path);
        if (mount_point == null) {
            return error.NoSuchFileOrDirectory;
        }
        
        // Get the root inode of the file system
        var inode = try mount_point.?.superblock.read_inode(1); // Root inode is typically 1
        if (inode == null) {
            return error.NoSuchFileOrDirectory;
        }
        
        // If path is just "/", return the root inode
        if (std.mem.eql(u8, path, "/")) {
            return inode;
        }
        
        // Split path into components
        var components = std.mem.splitSequence(u8, path, "/");
        
        // Skip empty components
        while (components.next()) |component| {
            if (component.len == 0) continue;
            
            // Look up the component in the current inode
            inode = try inode.?.lookup(component);
            if (inode == null) {
                return error.NoSuchFileOrDirectory;
            }
        }
        
        return inode;
    }
    
    pub fn create(self: *VirtualFileSystem, path: []const u8, mode: FileMode) anyerror!?*Inode {
        // Lock the VFS for writing
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Find the parent directory
        const parent_path = self.get_parent_path(path);
        const filename = self.get_filename(path);
        
        const parent_inode = try self.lookup(parent_path);
        if (parent_inode == null) {
            return error.NoSuchFileOrDirectory;
        }
        
        // Create the file
        return parent_inode.?.create(filename, mode);
    }
    
    pub fn mkdir(self: *VirtualFileSystem, path: []const u8, mode: FileMode) anyerror!void {
        // Lock the VFS for writing
        self.lock.acquire_write();
        defer self.lock.release_write();
        
        // Find the parent directory
        const parent_path = self.get_parent_path(path);
        const dirname = self.get_filename(path);
        
        const parent_inode = try self.lookup(parent_path);
        if (parent_inode == null) {
            return error.NoSuchFileOrDirectory;
        }
        
        // Create the directory
        try parent_inode.?.mkdir(dirname, mode);
    }
    
    fn create_superblock(self: *VirtualFileSystem, fs_type: FileSystemType, device_id: u64) anyerror!*Superblock {
        _ = self;
        // This would typically call into the specific file system implementation
        // For now, we'll create a placeholder superblock
        
        const superblock = try kheap.alloc(@sizeOf(Superblock), 8);
        
        // Set up operations based on file system type
        const ops = switch (fs_type) {
            .TMPFS => &tmpfs_superblock_ops,
            .PROCFS => &procfs_superblock_ops,
            .DEVFS => &devfs_superblock_ops,
            else => return error.FileSystemNotSupported,
        };
        
        const sb = @as(*Superblock, @alignCast(@ptrCast(superblock)));
        sb.* = Superblock{
            .fs_type = fs_type,
            .device_id = device_id,
            .block_size = 4096,
            .total_blocks = 0,
            .free_blocks = 0,
            .total_inodes = 0,
            .free_inodes = 0,
            .magic = 0,
            .state = 0,
            .ops = ops,
            .private_data = null,
            .lock = spinlock.RwSpinlock.init(),
        };
        
        return @as(*Superblock, @alignCast(@ptrCast(superblock)));
    }
    
    fn find_mount_point(self: *VirtualFileSystem, path: []const u8) ?*MountPoint {
        var best_match: ?*MountPoint = null;
        var best_len: usize = 0;
        
        var current = self.mount_points;
        while (current != null) {
            if (std.mem.startsWith(u8, path, current.?.mount_point) and current.?.mount_point.len > best_len) {
                best_match = current;
                best_len = current.?.mount_point.len;
            }
            current = current.?.next;
        }
        
        return best_match;
    }
    
    fn get_parent_path(self: *VirtualFileSystem, path: []const u8) []const u8 {
        _ = self;
        // Find the last '/'
        var last_slash: usize = 0;
        for (path, 0..) |c, i| {
            if (c == '/') {
                last_slash = i;
            }
        }
        
        if (last_slash == 0) {
            return "/";
        }
        
        return path[0..last_slash];
    }
    
    fn get_filename(self: *VirtualFileSystem, path: []const u8) []const u8 {
        _ = self;
        // Find the last '/'
        var last_slash: usize = 0;
        for (path, 0..) |c, i| {
            if (c == '/') {
                last_slash = i;
            }
        }
        
        if (last_slash == path.len - 1) {
            return "";
        }
        
        return path[last_slash + 1 ..];
    }
    
    fn duplicate_string(self: *VirtualFileSystem, str: []const u8) anyerror![]u8 {
        _ = self;
        const dup = try kheap.alloc(str.len, 1);
        const dup_slice = @as([*]u8, @ptrCast(dup))[0..str.len];
        @memcpy(dup_slice, str);
        return dup_slice;
    }
};

// Global VFS instance
var global_vfs: VirtualFileSystem = undefined;

// Initialize the VFS
pub fn init() !void {
    global_vfs = VirtualFileSystem.init();
    
    // Mount root file system (TMPFS)
    try global_vfs.mount(0, "/", .TMPFS, 0);
    
    // Mount PROCFS at /proc
    try global_vfs.mount(0, "/proc", .PROCFS, 0);
    
    // Mount DEVFS at /dev
    try global_vfs.mount(0, "/dev", .DEVFS, 0);
}

// Mount a file system
pub fn mount(device_id: u64, path: []const u8, fs_type: FileSystemType, flags: u32) !void {
    try global_vfs.mount(device_id, path, fs_type, flags);
}

// Unmount a file system
pub fn umount(path: []const u8) !void {
    try global_vfs.umount(path);
}

// Look up a file
pub fn lookup(path: []const u8) !?*Inode {
    return global_vfs.lookup(path);
}

// Create a file
pub fn create(path: []const u8, mode: FileMode) !?*Inode {
    return global_vfs.create(path, mode);
}

// Create a directory
pub fn mkdir(path: []const u8, mode: FileMode) !void {
    try global_vfs.mkdir(path, mode);
}

// Placeholder operations for TMPFS
const tmpfs_superblock_ops = SuperblockOperations{
    .alloc_inode = tmpfs_alloc_inode,
    .free_inode = tmpfs_free_inode,
    .write_inode = tmpfs_write_inode,
    .read_inode = tmpfs_read_inode,
    .statfs = tmpfs_statfs,
    .remount = null,
    .sync = null,
};

fn tmpfs_alloc_inode(__sb: *Superblock) anyerror!?*Inode {
    _ = __sb;
    // Placeholder implementation
    return null;
}

fn tmpfs_free_inode(__sb: *Superblock, __inode: *Inode) anyerror!void {
    _ = __sb;
    _ = __inode;
    // Placeholder implementation
}

fn tmpfs_write_inode(__sb: *Superblock, __inode: *Inode) anyerror!void {
    _ = __sb;
    _ = __inode;
    // Placeholder implementation
}

fn tmpfs_read_inode(__sb: *Superblock, __ino: u64) anyerror!?*Inode {
    _ = __sb;
    _ = __ino;
    // Placeholder implementation
    return null;
}

fn tmpfs_statfs(__sb: *Superblock, stats: *FileSystemStats) anyerror!void {
    _ = __sb;
    // Placeholder implementation
    stats.* = .{
        .total_blocks = 1024 * 1024, // 4GB
        .free_blocks = 1024 * 1024,
        .total_inodes = 1024 * 1024,
        .free_inodes = 1024 * 1024,
        .block_size = 4096,
        .max_filename_length = 255,
    };
}

// Placeholder operations for PROCFS
const procfs_superblock_ops = SuperblockOperations{
    .alloc_inode = procfs_alloc_inode,
    .free_inode = procfs_free_inode,
    .write_inode = procfs_write_inode,
    .read_inode = procfs_read_inode,
    .statfs = procfs_statfs,
    .remount = null,
    .sync = null,
};

fn procfs_alloc_inode(__sb: *Superblock) anyerror!?*Inode {
    _ = __sb;
    // Placeholder implementation
    return null;
}

fn procfs_free_inode(__sb: *Superblock, __inode: *Inode) anyerror!void {
    _ = __sb;
    _ = __inode;
    // Placeholder implementation
}

fn procfs_write_inode(__sb: *Superblock, __inode: *Inode) anyerror!void {
    _ = __sb;
    _ = __inode;
    // Placeholder implementation
}

fn procfs_read_inode(__sb: *Superblock, __ino: u64) anyerror!?*Inode {
    _ = __sb;
    _ = __ino;
    // Placeholder implementation
    return null;
}

fn procfs_statfs(__sb: *Superblock, stats: *FileSystemStats) anyerror!void {
    _ = __sb;
    // Placeholder implementation
    stats.* = .{
        .total_blocks = 0,
        .free_blocks = 0,
        .total_inodes = 0,
        .free_inodes = 0,
        .block_size = 4096,
        .max_filename_length = 255,
    };
}

// Placeholder operations for DEVFS
const devfs_superblock_ops = SuperblockOperations{
    .alloc_inode = devfs_alloc_inode,
    .free_inode = devfs_free_inode,
    .write_inode = devfs_write_inode,
    .read_inode = devfs_read_inode,
    .statfs = devfs_statfs,
    .remount = null,
    .sync = null,
};

fn devfs_alloc_inode(__sb: *Superblock) anyerror!?*Inode {
    _ = __sb;
    // Placeholder implementation
    return null;
}

fn devfs_free_inode(__sb: *Superblock, __inode: *Inode) anyerror!void {
    _ = __sb;
    _ = __inode;
    // Placeholder implementation
}

fn devfs_write_inode(__sb: *Superblock, __inode: *Inode) anyerror!void {
    _ = __sb;
    _ = __inode;
    // Placeholder implementation
}

fn devfs_read_inode(__sb: *Superblock, __ino: u64) anyerror!?*Inode {
    _ = __sb;
    _ = __ino;
    // Placeholder implementation
    return null;
}

fn devfs_statfs(__sb: *Superblock, stats: *FileSystemStats) anyerror!void {
    _ = __sb;
    // Placeholder implementation
    stats.* = .{
        .total_blocks = 0,
        .free_blocks = 0,
        .total_inodes = 0,
        .free_inodes = 0,
        .block_size = 4096,
        .max_filename_length = 255,
    };
}