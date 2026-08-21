const std = @import("std");

pub const SimulatedFile = struct {
    data: std.ArrayListUnmanaged(u8),
    cursor: usize,
    
    pub fn init() SimulatedFile {
        return .{
            .data = .empty,
            .cursor = 0,
        };
    }
    
    pub fn deinit(self: *SimulatedFile, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }
};

pub const Simulator = struct {
    allocator: std.mem.Allocator,
    files: std.AutoHashMap(std.posix.fd_t, *SimulatedFile),
    paths: std.StringHashMap(std.posix.fd_t),
    next_fd: std.posix.fd_t,
    current_time_ms: i64,
    vtable: std.Io.VTable,
    
    pub fn init(allocator: std.mem.Allocator) Simulator {
        var sim = Simulator{
            .allocator = allocator,
            .files = std.AutoHashMap(std.posix.fd_t, *SimulatedFile).init(allocator),
            .paths = std.StringHashMap(std.posix.fd_t).init(allocator),
            .next_fd = 100, // start fds from 100 to avoid standard fds
            .current_time_ms = 0,
            .vtable = std.Io.failing.vtable.*,
        };
        
        sim.vtable.sleep = mock_sleep;
        sim.vtable.timestamp = mock_timestamp;
        sim.vtable.dirCreateFile = mock_dirCreateFile;
        sim.vtable.dirOpenFile = mock_dirOpenFile;
        sim.vtable.operate = mock_operate;
        sim.vtable.fileClose = mock_fileClose;
        
        return sim;
    }
    
    pub fn deinit(self: *Simulator) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.files.deinit();
        
        var paths_it = self.paths.iterator();
        while (paths_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.paths.deinit();
    }
    
    pub fn io(self: *Simulator) std.Io {
        return .{
            .vtable = &self.vtable,
            .userdata = self,
        };
    }
};

fn mock_sleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const self: *Simulator = @ptrCast(@alignCast(userdata));
    if (timeout == .duration) {
        const ms = @as(i64, @intCast(timeout.duration.nanoseconds / 1_000_000));
        self.current_time_ms += ms;
    }
}

fn mock_timestamp(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Timestamp {
    _ = clock;
    const self: *Simulator = @ptrCast(@alignCast(userdata));
    return std.Io.Timestamp{ .nanoseconds = @as(u128, @intCast(self.current_time_ms)) * 1_000_000 };
}

fn mock_dirCreateFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, flags: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
    _ = dir; _ = flags;
    const self: *Simulator = @ptrCast(@alignCast(userdata));
    
    const fd = self.next_fd;
    self.next_fd += 1;
    
    if (self.paths.get(sub_path)) |existing_fd| {
        if (self.files.get(existing_fd)) |f| {
            f.data.clearRetainingCapacity();
            f.cursor = 0;
            return std.Io.File{ .handle = existing_fd, .flags = .{ .nonblocking = false } };
        }
    }
    
    const file = self.allocator.create(SimulatedFile) catch return error.SystemResources;
    file.* = SimulatedFile.init();
    self.files.put(fd, file) catch return error.SystemResources;
    self.paths.put(try self.allocator.dupe(u8, sub_path), fd) catch return error.SystemResources;
    
    return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn mock_dirOpenFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, flags: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    _ = dir; _ = flags;
    const self: *Simulator = @ptrCast(@alignCast(userdata));
    
    if (self.paths.get(sub_path)) |fd| {
        if (self.files.get(fd)) |f| {
            f.cursor = 0;
            return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
        }
    }
    return error.FileNotFound;
}

fn mock_fileClose(userdata: ?*anyopaque, files: []const std.Io.File) void {
    _ = userdata;
    _ = files;
}

fn mock_operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    const self: *Simulator = @ptrCast(@alignCast(userdata));
    
    return switch (operation) {
        .file_read_streaming => |fr| {
            if (self.files.get(fr.file.handle)) |f| {
                const remaining = f.data.items.len - f.cursor;
                if (remaining == 0) return .{ .file_read_streaming = 0 }; // EOF
                
                var total_read: usize = 0;
                for (fr.buffer) |buf| {
                    if (total_read >= remaining) break;
                    const to_read = @min(buf.len, remaining - total_read);
                    @memcpy(buf[0..to_read], f.data.items[f.cursor + total_read .. f.cursor + total_read + to_read]);
                    total_read += to_read;
                }
                
                f.cursor += total_read;
                return .{ .file_read_streaming = total_read };
            }
            return .{ .file_read_streaming = error.InputOutput };
        },
        .file_write_streaming => |fw| {
            if (self.files.get(fw.file.handle)) |f| {
                var total_written: usize = 0;
                if (fw.header.len > 0) {
                    f.data.appendSlice(self.allocator, fw.header) catch return .{ .file_write_streaming = error.InputOutput };
                    total_written += fw.header.len;
                }
                
                for (fw.data[0..fw.splat]) |buf| {
                    f.data.appendSlice(self.allocator, buf) catch return .{ .file_write_streaming = error.InputOutput };
                    total_written += buf.len;
                }
                f.cursor += total_written;
                return .{ .file_write_streaming = total_written };
            }
            return .{ .file_write_streaming = error.InputOutput };
        },
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
        else => unreachable,
    };
}

test "Simulator file mock" {
    var sim = Simulator.init(std.testing.allocator);
    defer sim.deinit();
    
    const my_io = sim.io();
    
    const dir = std.Io.Dir.cwd();
    const file = try std.Io.Dir.createFile(dir, my_io, "test.txt", .{});
    
    try std.Io.File.writeStreamingAll(file, my_io, "hello world");
    
    const file2 = try std.Io.Dir.openFile(dir, my_io, "test.txt", .{});
    var buf: [20]u8 = undefined;
    var bufs = [_][]u8{buf[0..]};
    const len = try std.Io.File.readStreaming(file2, my_io, &bufs);
    
    try std.testing.expectEqualStrings("hello world", buf[0..len]);
}
