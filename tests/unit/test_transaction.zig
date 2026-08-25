const std = @import("std");
const TransactionContext = @import("../../src/storage/wal/transaction.zig").TransactionContext;
const ActiveSnapshot = @import("../../src/storage/wal/transaction.zig").ActiveSnapshot;

test "is_visible: system transaction (xmin=0) is always visible" {
    const ctx = TransactionContext{ .txn_id = 10 };
    try std.testing.expect(ctx.is_visible(0, 0));
}

test "is_visible: read-your-writes (xmin == txn_id)" {
    const ctx = TransactionContext{ .txn_id = 7 };
    try std.testing.expect(ctx.is_visible(7, 0));
}

test "is_visible: row committed before snapshot (xmin < txn_id, no snapshot)" {
    const ctx = TransactionContext{ .txn_id = 10 };
    try std.testing.expect(ctx.is_visible(3, 0));
}

test "is_visible: row created by a future transaction is invisible" {
    const ctx = TransactionContext{ .txn_id = 5 };
    try std.testing.expect(!ctx.is_visible(9, 0));
}

test "is_visible: row created by a txn active at snapshot time is invisible" {
    var snap = ActiveSnapshot{};
    try snap.append(4);

    var ctx = TransactionContext{ .txn_id = 10, .active_snapshot = snap };
    defer ctx.deinit(); // owns + frees active_snapshot

    // xmin=4 is in the active snapshot → not yet committed when we started
    try std.testing.expect(!ctx.is_visible(4, 0));
}

test "is_visible: tombstone sentinel (xmax == maxInt) hides row" {
    const ctx = TransactionContext{ .txn_id = 10 };
    try std.testing.expect(!ctx.is_visible(3, std.math.maxInt(u32)));
}

test "is_visible: deleted by a future transaction (xmax > txn_id) still visible" {
    const ctx = TransactionContext{ .txn_id = 5 };
    try std.testing.expect(ctx.is_visible(3, 9));
}

test "is_visible: deleted by an already-committed transaction (xmax < txn_id) is invisible" {
    const ctx = TransactionContext{ .txn_id = 10 };
    try std.testing.expect(!ctx.is_visible(3, 6));
}

test "is_visible: deletion by a txn active at snapshot time is not visible (snapshot isolation)" {
    var snap = ActiveSnapshot{};
    try snap.append(8);

    var ctx = TransactionContext{ .txn_id = 10, .active_snapshot = snap };
    defer ctx.deinit(); // owns + frees active_snapshot

    // Deleter (xmax=8) was active when we snapshot, so its delete does not apply to us.
    try std.testing.expect(ctx.is_visible(3, 8));
}
