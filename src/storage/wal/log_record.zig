const std = @import("std");

pub const LogRecordType = enum(u8) {
    begin = 0,
    commit = 1,
    abort = 2,
    insert_tuple = 3,
    delete_tuple = 4,
    update_tuple = 5,
    update_page_meta = 6,
    checkpoint = 7,
    logical_insert = 8,
    logical_delete = 9,
    prepare_txn = 10,
    raft_config_change = 11,
};

pub const LogRecordHeader = extern struct {
    lsn: u32,
    prev_lsn: u32,
    txn_id: u32,
    term: u64,
    length: u32, // Length of the entire record including header and payload
    page_id: u32,
    offset: u16,
    record_type: LogRecordType,
    _padding: u8,
};

// Represents a log record in memory
pub const LogRecord = struct {
    header: LogRecordHeader,
    payload: []const u8,

    pub fn deinit(self: *LogRecord, allocator: std.mem.Allocator) void {
        if (self.payload.len > 0) {
            allocator.free(self.payload);
        }
    }
};
