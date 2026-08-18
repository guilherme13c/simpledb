const std = @import("std");
const page = @import("../page/page.zig");

pub const StorageManager = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,

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

        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
        };
    }

    pub fn deinit(self: *StorageManager) void {
        self.file.close(self.io);
    }

    pub fn read_page(self: *StorageManager, page_id: u32, destination: *page.Page) !void {
        const offset = page_id * page.page_size;
        const data = @as([*]u8, @ptrCast(destination))[0..page.page_size];
        var bufs = [_][]u8{data};
        _ = try self.file.readPositional(self.io, &bufs, offset);
    }

    pub fn write_page(self: *StorageManager, page_id: u32, source: *const page.Page) !void {
        const offset = page_id * page.page_size;
        const data = @as([*]const u8, @ptrCast(source))[0..page.page_size];
        const bufs = [_][]const u8{data};
        _ = try self.file.writePositional(self.io, &bufs, offset);
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
