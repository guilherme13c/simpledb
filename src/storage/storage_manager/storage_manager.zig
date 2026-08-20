const std = @import("std");
const page = @import("../page/page.zig");

pub const IoContext = struct {
    res: i32,
    done: std.atomic.Value(bool),
    io: std.Io,
};

pub const StorageManager = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    ring: std.os.linux.IoUring,
    fd: std.posix.fd_t,
    filename: []const u8,
    ring_mutex: std.Io.Mutex,
    leader_lock: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !StorageManager {
        var flags = std.posix.O{ .ACCMODE = .RDWR, .CREAT = true, .DIRECT = true };
        const fd = std.posix.openat(std.posix.AT.FDCWD, file_path, flags, 0o666) catch |err| blk: {
            if (err == error.InvalidArgument) {
                flags.DIRECT = false;
                break :blk try std.posix.openat(std.posix.AT.FDCWD, file_path, flags, 0o666);
            }
            return err;
        };
        const file = std.Io.File{
            .handle = fd,
            .flags = .{ .nonblocking = false },
        };
        
        const ring = try std.os.linux.IoUring.init(256, 0);

        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .ring = ring,
            .fd = fd,
            .filename = file_path,
            .ring_mutex = .init,
            .leader_lock = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn start(self: *StorageManager) !void {
        _ = self;
    }

    fn wait_for_cqe(self: *StorageManager, ctx: *IoContext) !void {
        while (!ctx.done.load(.acquire)) {
            // Try to become the Leader
            if (!self.leader_lock.swap(true, .acquire)) {
                defer self.leader_lock.store(false, .release);

                // Double-check if we finished while acquiring lock
                if (ctx.done.load(.acquire)) break;

                const flags: u32 = std.os.linux.IORING_ENTER_GETEVENTS;
                
                // If there are other threads, they might have submitted.
                _ = self.ring.enter(0, 1, flags) catch |err| {
                    if (err == error.SignalInterrupt) continue;
                    // Ignore error
                };

                var cqes: [64]std.os.linux.io_uring_cqe = undefined;
                while (true) {
                    const count = self.ring.copy_cqes(&cqes, 0) catch 0;
                    if (count == 0) break;
                    
                    for (cqes[0..count]) |cqe| {
                        if (cqe.user_data != 0) {
                            const other_ctx = @as(*IoContext, @ptrFromInt(cqe.user_data));
                            other_ctx.res = cqe.res;
                            other_ctx.done.store(true, .release);
                        }
                    }
                }
            } else {
                // We are a Follower. Wait for the Leader to process our CQE.
                // If the Leader leaves before our CQE arrives, we will wake up and become the new Leader.
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn deinit(self: *StorageManager) void {
        self.ring.deinit();
        self.file.close(self.io);
    }

    pub fn read_page(self: *StorageManager, page_id: u32, destination: *page.Page) !void {
        const offset = page_id * page.page_size;
        const data = @as([*]u8, @ptrCast(destination))[0..page.page_size];
        

        var ctx = IoContext{
            .res = 0,
            .done = std.atomic.Value(bool).init(false),
            .io = self.io,
        };
        
        self.ring_mutex.lockUncancelable(self.io);
        var sqe = self.ring.get_sqe() catch blk: {
            while (self.ring.sq_ready() > 0) {
                _ = self.ring.submit() catch 0;
            }
            break :blk self.ring.get_sqe() catch {
                self.ring_mutex.unlock(self.io);
                return error.IoError;
            };
        };
        sqe.prep_read(self.file.handle, data, offset);
        sqe.user_data = @intFromPtr(&ctx);

        while (self.ring.sq_ready() > 0) {
            _ = self.ring.submit() catch |err| {
                if (err == error.SignalInterrupt) continue;
                self.ring_mutex.unlock(self.io);
                return error.IoError;
            };
        }
        self.ring_mutex.unlock(self.io);
        
        try self.wait_for_cqe(&ctx);
        if (ctx.res < 0) return error.IoError;
        
        const bytes_read: usize = @intCast(ctx.res);
        if (bytes_read < page.page_size) {
            @memset(data[bytes_read..], 0);
        }
    }

    pub fn read_pages(self: *StorageManager, page_ids: []const u32, destinations: []const *page.Page) !void {
        var contexts: [128]IoContext = undefined;
        const count = page_ids.len;
        if (count == 0) return;
        if (count > 128) return error.TooManyPages;

        for (0..count) |i| {
            contexts[i] = IoContext{
                .res = 0,
                .done = std.atomic.Value(bool).init(false),
                .io = self.io,
            };
        }

        self.ring_mutex.lockUncancelable(self.io);
        for (0..count) |i| {
            const offset = page_ids[i] * page.page_size;
            const data = @as([*]u8, @ptrCast(destinations[i]))[0..page.page_size];
            var sqe = self.ring.get_sqe() catch blk: {
                while (self.ring.sq_ready() > 0) {
                    _ = self.ring.submit() catch 0;
                }
                break :blk self.ring.get_sqe() catch {
                    self.ring_mutex.unlock(self.io);
                    return error.IoError;
                };
            };
            sqe.prep_read(self.file.handle, data, offset);
            sqe.user_data = @intFromPtr(&contexts[i]);
        }
        
        while (self.ring.sq_ready() > 0) {
            _ = self.ring.submit() catch |err| {
                if (err == error.SignalInterrupt) continue;
                self.ring_mutex.unlock(self.io);
                std.debug.print("io_uring read_pages submit error: {}\n", .{err});
                return error.IoError;
            };
        }
        self.ring_mutex.unlock(self.io);
        
        for (0..count) |i| {
            try self.wait_for_cqe(&contexts[i]);
            if (contexts[i].res < 0) return error.IoError;
            
            const bytes_read: usize = @intCast(contexts[i].res);
            if (bytes_read < page.page_size) {
                const data = @as([*]u8, @ptrCast(destinations[i]))[0..page.page_size];
                @memset(data[bytes_read..], 0);
            }
        }
    }

    pub fn write_page(self: *StorageManager, page_id: u32, source: *const page.Page) !void {
        const offset = page_id * page.page_size;
        const data = @as([*]const u8, @ptrCast(source))[0..page.page_size];
        
        var ctx = IoContext{
            .res = 0,
            .done = std.atomic.Value(bool).init(false),
            .io = self.io,
        };
        
        self.ring_mutex.lockUncancelable(self.io);
        var sqe = self.ring.get_sqe() catch blk: {
            while (self.ring.sq_ready() > 0) {
                _ = self.ring.submit() catch 0;
            }
            break :blk self.ring.get_sqe() catch {
                self.ring_mutex.unlock(self.io);
                return error.IoError;
            };
        };
        sqe.prep_write(self.file.handle, data, offset);
        sqe.user_data = @intFromPtr(&ctx);

        while (self.ring.sq_ready() > 0) {
            _ = self.ring.submit() catch |err| {
                if (err == error.SignalInterrupt) continue;
                self.ring_mutex.unlock(self.io);
                return error.IoError;
            };
        }
        self.ring_mutex.unlock(self.io);
        
        try self.wait_for_cqe(&ctx);
        if (ctx.res < 0) return error.IoError;
    }

    pub fn write_pages(self: *StorageManager, page_ids: []const u32, sources: []const *const page.Page) !void {
        var contexts: [128]IoContext = undefined;
        const count = page_ids.len;
        if (count == 0) return;
        if (count > 128) return error.TooManyPages;

        for (0..count) |i| {
            contexts[i] = IoContext{
                .res = 0,
                .done = std.atomic.Value(bool).init(false),
                .io = self.io,
            };
        }

        self.ring_mutex.lockUncancelable(self.io);
        for (0..count) |i| {
            const offset = page_ids[i] * page.page_size;
            const data = @as([*]const u8, @ptrCast(sources[i]))[0..page.page_size];
            var sqe = self.ring.get_sqe() catch blk: {
                while (self.ring.sq_ready() > 0) {
                    _ = self.ring.submit() catch 0;
                }
                break :blk self.ring.get_sqe() catch {
                    self.ring_mutex.unlock(self.io);
                    return error.IoError;
                };
            };
            sqe.prep_write(self.file.handle, data, offset);
            sqe.user_data = @intFromPtr(&contexts[i]);
        }

        while (self.ring.sq_ready() > 0) {
            _ = self.ring.submit() catch |err| {
                if (err == error.SignalInterrupt) continue;
                self.ring_mutex.unlock(self.io);
                std.debug.print("io_uring write_pages submit error: {}\n", .{err});
                return error.IoError;
            };
        }
        self.ring_mutex.unlock(self.io);
        
        for (0..count) |i| {
            try self.wait_for_cqe(&contexts[i]);
            if (contexts[i].res < 0) return error.IoError;
        }
    }

    pub fn get_file_size(self: *StorageManager) !u64 {
        const stat = try self.file.stat(self.io);
        return stat.size;
    }
};

test "StorageManager read and write" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    
    const io = threaded_io.io();
    
    // We'll use a temporary test db file
    const test_db = "test_storage.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    
    var sm = try StorageManager.init(std.testing.allocator, io, test_db);
    try sm.start();
    defer sm.deinit();

    var p: page.Page = undefined;
    p.header.lsn = 999;
    
    // Write to page 0
    try sm.write_page(0, &p);

    var p2: page.Page = undefined;
    
    // Read from page 0
    try sm.read_page(0, &p2);

    try std.testing.expectEqual(@as(u22, 999), p2.header.lsn);
}
