const std = @import("std");

pub const TransactionContext = struct {
    txn_id: u32,
    prev_lsn: u32 = 0,
    lock_manager: ?*@import("../concurrency/lock_manager.zig").LockManager = null,
    active_snapshot: ?std.AutoHashMap(u32, void) = null,

    pub fn deinit(self: *TransactionContext) void {
        if (self.active_snapshot) |*snap| {
            snap.deinit();
        }
    }

    pub fn is_visible(self: *const TransactionContext, xmin: u32, xmax: u32) bool {
        // xmin = 0 is a special system transaction (always visible)
        const created_visible = (xmin == 0) or (xmin == self.txn_id) or 
            ((xmin < self.txn_id) and (self.active_snapshot == null or !self.active_snapshot.?.contains(xmin)));
        
        if (!created_visible) return false;

        if (xmax == std.math.maxInt(u32)) return false;

        const not_deleted = (xmax == 0) or (xmax > self.txn_id) or 
            (self.active_snapshot != null and self.active_snapshot.?.contains(xmax));

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
