const std = @import("std");
const log_record = @import("../../src/storage/wal/log_record.zig");
const LogRecordType = log_record.LogRecordType;
const LogRecordHeader = log_record.LogRecordHeader;

test "LogRecordType has stable on-disk u8 tags" {
    // These tags are part of the persisted WAL format; changing them breaks recovery.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(LogRecordType.begin));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(LogRecordType.commit));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(LogRecordType.abort));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(LogRecordType.insert_tuple));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(LogRecordType.delete_tuple));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(LogRecordType.update_tuple));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(LogRecordType.update_page_meta));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(LogRecordType.checkpoint));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(LogRecordType.logical_insert));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(LogRecordType.logical_delete));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(LogRecordType.prepare_txn));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(LogRecordType.raft_config_change));
}

test "LogRecordHeader is an extern struct (stable byte layout)" {
    const ti = @typeInfo(LogRecordHeader);
    try std.testing.expect(ti == .@"struct");
    try std.testing.expect(ti.@"struct".layout == .@"extern");
}

test "LogRecordHeader byte roundtrip preserves all fields" {
    const original = LogRecordHeader{
        .lsn = 0x1234,
        .prev_lsn = 0x2345,
        .txn_id = 0x3456,
        .term = 0x4567_89AB_CDEF,
        .length = 0x5678,
        .page_id = 0x6789,
        .offset = 0x7890,
        .record_type = .logical_insert,
        ._padding = 0,
    };

    var buf: [@sizeOf(LogRecordHeader)]u8 align(@alignOf(LogRecordHeader)) = undefined;
    @as(*LogRecordHeader, @ptrCast(&buf)).* = original;

    const restored = @as(*const LogRecordHeader, @ptrCast(&buf)).*;
    try std.testing.expectEqual(original.lsn, restored.lsn);
    try std.testing.expectEqual(original.prev_lsn, restored.prev_lsn);
    try std.testing.expectEqual(original.txn_id, restored.txn_id);
    try std.testing.expectEqual(original.term, restored.term);
    try std.testing.expectEqual(original.length, restored.length);
    try std.testing.expectEqual(original.page_id, restored.page_id);
    try std.testing.expectEqual(original.offset, restored.offset);
    try std.testing.expectEqual(original.record_type, restored.record_type);
}

test "LogRecord.deinit frees payload and tolerates empty payload" {
    const payload = try std.testing.allocator.dupe(u8, "abc");
    var rec = log_record.LogRecord{ .header = std.mem.zeroes(LogRecordHeader), .payload = payload };
    rec.deinit(std.testing.allocator);

    var empty = log_record.LogRecord{ .header = std.mem.zeroes(LogRecordHeader), .payload = &[_]u8{} };
    empty.deinit(std.testing.allocator); // must not double-free / crash
}
