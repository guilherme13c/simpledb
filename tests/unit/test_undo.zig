const std = @import("std");
const undo = @import("../../src/server/undo.zig");

const A = std.testing.allocator;

test "clear_undo_stack: frees all entries and clears list" {
    var stack = std.ArrayList(undo.UndoOp).empty;
    defer stack.deinit(A);

    const t = try A.dupe(u8, "users");
    const tn = try A.dupe(u8, "items");
    const v = try A.dupe(u8, "payload");
    try stack.append(A, .{ .delete_key = .{ .table_name = t, .key = 42 } });
    try stack.append(A, .{ .insert_key = .{ .table_name = tn, .key = 7, .value = v } });

    try std.testing.expectEqual(@as(usize, 2), stack.items.len);
    undo.clear_undo_stack(&stack, A);

    try std.testing.expectEqual(@as(usize, 0), stack.items.len);
}
