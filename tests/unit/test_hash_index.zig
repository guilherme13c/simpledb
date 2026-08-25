const std = @import("std");
const HashIndex = @import("../../src/storage/index/hash_index.zig").HashIndex;

test "HashIndex insert and point search" {
    var idx = HashIndex.init(std.testing.allocator);
    defer idx.deinit();

    try idx.insert(100, 0xAAA);
    try idx.insert(200, 0xBBB);

    const r100 = try idx.search(std.testing.allocator, 100);
    defer std.testing.allocator.free(r100);
    try std.testing.expectEqualDeep(&[_]u64{0xAAA}, r100);

    const r200 = try idx.search(std.testing.allocator, 200);
    defer std.testing.allocator.free(r200);
    try std.testing.expectEqualDeep(&[_]u64{0xBBB}, r200);
}

test "HashIndex collision: multiple rids under one key" {
    var idx = HashIndex.init(std.testing.allocator);
    defer idx.deinit();

    try idx.insert(42, 1);
    try idx.insert(42, 2);
    try idx.insert(42, 3);

    const rids = try idx.search(std.testing.allocator, 42);
    defer std.testing.allocator.free(rids);
    try std.testing.expectEqual(@as(usize, 3), rids.len);
    try std.testing.expectEqualDeep(&[_]u64{ 1, 2, 3 }, rids);
}

test "HashIndex delete removes the specific rid only" {
    var idx = HashIndex.init(std.testing.allocator);
    defer idx.deinit();

    try idx.insert(42, 1);
    try idx.insert(42, 2);
    try idx.insert(42, 3);

    idx.delete(42, 2); // remove middle

    const rids = try idx.search(std.testing.allocator, 42);
    defer std.testing.allocator.free(rids);
    // swapRemove reorders; remaining set must be {1, 3}
    try std.testing.expectEqual(@as(usize, 2), rids.len);
    var found_1 = false;
    var found_3 = false;
    for (rids) |r| {
        if (r == 1) found_1 = true;
        if (r == 3) found_3 = true;
    }
    try std.testing.expect(found_1 and found_3);
}

test "HashIndex delete last rid removes the key entry" {
    var idx = HashIndex.init(std.testing.allocator);
    defer idx.deinit();

    try idx.insert(99, 7);
    idx.delete(99, 7);

    const rids = try idx.search(std.testing.allocator, 99);
    defer std.testing.allocator.free(rids);
    try std.testing.expectEqual(@as(usize, 0), rids.len);
}

test "HashIndex delete non-existent key/rid is a no-op" {
    var idx = HashIndex.init(std.testing.allocator);
    defer idx.deinit();

    try idx.insert(1, 1);
    idx.delete(999, 1); // missing key
    idx.delete(1, 999); // missing rid under existing key

    const rids = try idx.search(std.testing.allocator, 1);
    defer std.testing.allocator.free(rids);
    try std.testing.expectEqualDeep(&[_]u64{1}, rids);
}

test "HashIndex search missing key returns empty slice" {
    var idx = HashIndex.init(std.testing.allocator);
    defer idx.deinit();

    const rids = try idx.search(std.testing.allocator, 404);
    defer std.testing.allocator.free(rids);
    try std.testing.expectEqual(@as(usize, 0), rids.len);
}
