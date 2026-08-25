const std = @import("std");

pub const ActiveSnapshot = struct {
    items: [256]u32 = undefined,
    len: usize = 0,

    pub fn append(self: *ActiveSnapshot, val: u32) !void {
        if (self.len >= 256) return error.TooManyActiveTransactions;
        self.items[self.len] = val;
        self.len += 1;
    }

    pub fn slice(self: *const ActiveSnapshot) []const u32 {
        return self.items[0..self.len];
    }
};

pub const TransactionContext = struct {
    txn_id: u32,
    prev_lsn: u32 = 0,
    lock_manager: ?*@import("../concurrency/lock_manager.zig").LockManager = null,
    active_snapshot: ?ActiveSnapshot = null,

    pub fn deinit(self: *TransactionContext) void {
        _ = self;
    }

    pub fn is_visible(self: *const TransactionContext, xmin: u32, xmax: u32) bool {
        // xmin = 0 is a special system transaction (always visible)
        var not_in_snap = true;
        if (self.active_snapshot) |*snap| {
            for (snap.slice()) |active_id| {
                if (active_id == xmin) {
                    not_in_snap = false;
                    break;
                }
            }
        }
        const created_visible = (xmin == 0) or (xmin == self.txn_id) or
            ((xmin < self.txn_id) and not_in_snap);

        if (!created_visible) return false;

        if (xmax == std.math.maxInt(u32)) return false;

        var in_snap = false;
        if (self.active_snapshot) |*snap| {
            for (snap.slice()) |active_id| {
                if (active_id == xmax) {
                    in_snap = true;
                    break;
                }
            }
        }

        const not_deleted = (xmax == 0) or (xmax > self.txn_id) or in_snap;

        return not_deleted;
    }

    pub fn lock_row_shared(self: *TransactionContext, root_page_id: u32, rid: u64) !void {
        _ = self;
        _ = root_page_id;
        _ = rid;
        // No-op for MVCC: Readers do not block writers.
    }

    pub fn lock_row_exclusive(self: *TransactionContext, root_page_id: u32, rid: u64) !void {
        if (self.lock_manager) |lm| {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&root_page_id));
            hasher.update(std.mem.asBytes(&rid));
            try lm.lock_exclusive(self.txn_id, hasher.final());
        }
    }
};
