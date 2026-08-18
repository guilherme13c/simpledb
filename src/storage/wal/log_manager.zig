const std = @import("std");
const log_record = @import("log_record.zig");
const LogRecordHeader = log_record.LogRecordHeader;
const LogRecordType = log_record.LogRecordType;

pub const LogManager = struct {
    io: std.Io,
    wal_file: std.Io.File,
    mutex: std.Io.Mutex,
    global_lsn: std.atomic.Value(u32),
    flushed_lsn: std.atomic.Value(u32),
    current_offset: u32, // The physical offset in the file, which we use as the LSN

    pub fn init(io: std.Io, wal_file: std.Io.File) !LogManager {
        const stat = try wal_file.stat(io);
        return LogManager{
            .io = io,
            .wal_file = wal_file,
            .mutex = .init,
            .global_lsn = std.atomic.Value(u32).init(@as(u32, @intCast(stat.size))),
            .flushed_lsn = std.atomic.Value(u32).init(@as(u32, @intCast(stat.size))),
            .current_offset = @as(u32, @intCast(stat.size)),
        };
    }

    pub fn append_record(
        self: *LogManager,
        txn_id: u32,
        prev_lsn: u32,
        record_type: LogRecordType,
        page_id: u32,
        offset: u16,
        payload: []const u8,
    ) !u32 {
        const header_size = @sizeOf(LogRecordHeader);
        const total_size = header_size + payload.len;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const current_lsn = self.current_offset;
        
        var header = LogRecordHeader{
            .lsn = current_lsn,
            .prev_lsn = prev_lsn,
            .txn_id = txn_id,
            .length = @as(u32, @intCast(total_size)),
            .page_id = page_id,
            .offset = offset,
            .record_type = record_type,
            ._padding = 0,
        };

        const header_bytes = std.mem.asBytes(&header);
        _ = try self.wal_file.writePositional(self.io, &[_][]const u8{header_bytes}, current_lsn);
        
        if (payload.len > 0) {
            _ = try self.wal_file.writePositional(self.io, &[_][]const u8{payload}, current_lsn + header_size);
        }

        self.current_offset += @as(u32, @intCast(total_size));
        self.global_lsn.store(self.current_offset, .release);

        return current_lsn;
    }

    pub fn flush(self: *LogManager, lsn: u32) !void {
        if (self.flushed_lsn.load(.acquire) >= lsn) {
            return; // Already flushed
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Double checked locking
        if (self.flushed_lsn.load(.acquire) >= lsn) {
            return;
        }

        // Trigger a fsync (or fdatasync) on the wal file
        try self.wal_file.sync(self.io);
        
        self.flushed_lsn.store(self.current_offset, .release);
    }
};

test "LogManager append and flush" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_wal = "test_log_mgr.wal";
    defer std.Io.Dir.cwd().deleteFile(io, test_wal) catch {};
    
    const dir = std.Io.Dir.cwd();
    const wal_file = try std.Io.Dir.createFile(dir, io, test_wal, .{ .read = true, .truncate = true });
    
    var log_mgr = try LogManager.init(io, wal_file);
    
    const lsn1 = try log_mgr.append_record(1, 0, .begin, 0, 0, &[_]u8{});
    try std.testing.expectEqual(@as(u32, 0), lsn1);
    
    const lsn2 = try log_mgr.append_record(1, lsn1, .insert_tuple, 5, 0, "test_payload");
    try std.testing.expect(lsn2 > lsn1);
    
    // Test flush
    try log_mgr.flush(lsn2);
    try std.testing.expect(log_mgr.flushed_lsn.load(.acquire) >= lsn2);
    
    wal_file.close(io);
}
