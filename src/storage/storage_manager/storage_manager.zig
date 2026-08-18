const std = @import("std");
const page = @import("../page/page.zig");

pub const IoContext = struct {
    sem: std.Io.Semaphore,
    res: i32,
    io: std.Io,
};

pub const StorageManager = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    ring: std.os.linux.IoUring,
    ring_mutex: std.Io.Mutex,
    poller_thread: std.Thread,
    stop_poller: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !StorageManager {
        const dir = std.Io.Dir.cwd();

        const file = try std.Io.Dir.createFile(
            dir,
            io,
            file_path,
            .{
                .read = true,
                .truncate = false,
            },
        );
        
        const ring = try std.os.linux.IoUring.init(256, 0);

        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .ring = ring,
            .ring_mutex = .init,
            .poller_thread = undefined,
            .stop_poller = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn start(self: *StorageManager) !void {
        self.poller_thread = try std.Thread.spawn(.{}, poller_loop, .{self});
    }

    fn poller_loop(self: *StorageManager) void {
        while (!self.stop_poller.load(.monotonic)) {
            const wait_res = self.ring.enter(0, 1, std.os.linux.IORING_ENTER_GETEVENTS);
            if (wait_res) |_| {
                var cqes: [64]std.os.linux.io_uring_cqe = undefined;
                while (true) {
                    const count = self.ring.copy_cqes(&cqes, 0) catch 0;
                    if (count == 0) break;
                    
                    for (cqes[0..count]) |cqe| {
                        if (cqe.user_data != 0) {
                            const ctx = @as(*IoContext, @ptrFromInt(cqe.user_data));
                            ctx.res = cqe.res;
                            ctx.sem.post(ctx.io);
                        }
                    }
                }
            } else |err| {
                if (err == error.SignalInterrupt) continue;
                std.debug.print("io_uring wait_cqe error: {}\n", .{err});
                break;
            }
        }
    }

    pub fn deinit(self: *StorageManager) void {
        self.stop_poller.store(true, .monotonic);
        
        // Wake up poller thread by submitting a NOP
        self.ring_mutex.lockUncancelable(self.io);
        if (self.ring.get_sqe()) |sqe| {
            sqe.prep_nop();
            sqe.user_data = 0;
            _ = self.ring.submit() catch 0;
        } else |_| {}
        self.ring_mutex.unlock(self.io);
        
        self.poller_thread.join();
        self.ring.deinit();
        self.file.close(self.io);
    }

    pub fn read_page(self: *StorageManager, page_id: u32, destination: *page.Page) !void {
        const offset = page_id * page.page_size;
        const data = @as([*]u8, @ptrCast(destination))[0..page.page_size];
        var bufs = [_]std.posix.iovec{ .{ .base = data.ptr, .len = data.len } };
        
        var ctx = IoContext{
            .sem = .{ .permits = 0 },
            .res = 0,
            .io = self.io,
        };
        
        self.ring_mutex.lockUncancelable(self.io);
        var sqe = self.ring.get_sqe() catch blk: {
            _ = self.ring.submit() catch 0;
            break :blk self.ring.get_sqe() catch {
                self.ring_mutex.unlock(self.io);
                return error.IoError;
            };
        };
        sqe.prep_readv(self.file.handle, &bufs, offset);
        sqe.user_data = @intFromPtr(&ctx);
        _ = self.ring.submit() catch |err| {
            self.ring_mutex.unlock(self.io);
            std.debug.print("io_uring read_page submit error: {}\n", .{err});
            return error.IoError;
        };
        self.ring_mutex.unlock(self.io);
        
        ctx.sem.waitUncancelable(self.io);
        if (ctx.res < 0) return error.IoError;
    }

    pub fn write_page(self: *StorageManager, page_id: u32, source: *const page.Page) !void {
        const offset = page_id * page.page_size;
        const data = @as([*]const u8, @ptrCast(source))[0..page.page_size];
        var bufs = [_]std.posix.iovec_const{ .{ .base = data.ptr, .len = data.len } };
        
        var ctx = IoContext{
            .sem = .{ .permits = 0 },
            .res = 0,
            .io = self.io,
        };
        
        self.ring_mutex.lockUncancelable(self.io);
        var sqe = self.ring.get_sqe() catch blk: {
            _ = self.ring.submit() catch 0;
            break :blk self.ring.get_sqe() catch {
                self.ring_mutex.unlock(self.io);
                return error.IoError;
            };
        };
        sqe.prep_writev(self.file.handle, &bufs, offset);
        sqe.user_data = @intFromPtr(&ctx);
        _ = self.ring.submit() catch |err| {
            self.ring_mutex.unlock(self.io);
            std.debug.print("io_uring write_page submit error: {}\n", .{err});
            return error.IoError;
        };
        self.ring_mutex.unlock(self.io);
        
        ctx.sem.waitUncancelable(self.io);
        if (ctx.res < 0) return error.IoError;
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
