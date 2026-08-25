const std = @import("std");
const page = @import("../../src/storage/page/page.zig");
const SlottedView = @import("../../src/storage/page/slotted_view.zig").SlottedView;
const Slot = @import("../../src/storage/page/slotted_view.zig").Slot;

test "SlottedView: insert with header preserves header + data bytes" {
    var raw = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw, true);

    const mvcc_header = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const slot = try view.insert_tuple(&mvcc_header, "payload");

    const got = view.get_tuple(slot).?;
    // Stored tuple is header immediately followed by data.
    try std.testing.expectEqual(@as(usize, 8 + "payload".len), got.len);
    try std.testing.expectEqualSlices(u8, &mvcc_header, got[0..8]);
    try std.testing.expectEqualStrings("payload", got[8..]);
}

test "SlottedView: header bookkeeping after inserts" {
    var raw = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw, true);

    // Fresh page: lower=0, upper=content_length (full free space).
    try std.testing.expectEqual(@as(u13, 0), raw.header.lower);
    try std.testing.expectEqual(page.content_length, raw.header.upper);

    const slot0 = try view.insert_tuple(null, "ab"); // 2 data bytes
    try std.testing.expectEqual(@as(u16, 0), slot0);
    try std.testing.expectEqual(@as(u13, @sizeOf(Slot)), raw.header.lower);
    try std.testing.expectEqual(@as(u13, page.content_length - 2), raw.header.upper);

    const slot1 = try view.insert_tuple(null, "cde"); // 3 data bytes
    try std.testing.expectEqual(@as(u16, 1), slot1);
    try std.testing.expectEqual(@as(u13, 2 * @sizeOf(Slot)), raw.header.lower);
    try std.testing.expectEqual(@as(u13, page.content_length - 5), raw.header.upper);
}

test "SlottedView: get on out-of-range slot returns null" {
    var raw = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw, true);

    _ = try view.insert_tuple(null, "x");
    try std.testing.expect(view.get_tuple(0) != null);
    try std.testing.expect(view.get_tuple(1) == null); // no slot 1 yet
    try std.testing.expect(view.get_tuple(9999) == null); // far out of range
}

test "SlottedView: exact-fit boundary then over-fill fails" {
    var raw = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw, true);

    // Free space = content_length. Each insert consumes (payload + slot_size).
    // Insert a payload that leaves exactly (slot_size - 1) bytes free → next insert must fail.
    const slot_size = @sizeOf(Slot);
    const remaining_for_one_more = slot_size - 1;
    const big_len = page.content_length - slot_size - remaining_for_one_more;

    const big = try std.testing.allocator.alloc(u8, big_len);
    defer std.testing.allocator.free(big);
    @memset(big, 'Z');

    _ = try view.insert_tuple(null, big);

    // Only `remaining_for_one_more` bytes left, but an insert needs payload+slot_size >= slot_size.
    const err = view.insert_tuple(null, "1");
    try std.testing.expectError(error.OutOfSpace, err);
}

test "SlottedView: update_xmax rewrites the deletion-id bytes" {
    var raw = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw, true);

    const header8 = [_]u8{ 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // xmin=5, xmax=0
    const slot = try view.insert_tuple(&header8, "row");

    try view.update_xmax(slot, 42);

    const got = view.get_tuple(slot).?;
    const xmin = std.mem.readInt(u32, got[0..4], .little);
    const xmax = std.mem.readInt(u32, got[4..8], .little);
    try std.testing.expectEqual(@as(u32, 5), xmin);
    try std.testing.expectEqual(@as(u32, 42), xmax);
    try std.testing.expectEqualStrings("row", got[8..]);
}

test "SlottedView: update_xmax errors on invalid slot and short tuple" {
    var raw = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw, true);

    try std.testing.expectError(error.InvalidSlot, view.update_xmax(5, 1)); // no slots exist

    // Tuple shorter than the 8-byte mvcc header.
    const slot = try view.insert_tuple(null, "tiny"); // 4 bytes, < 8
    try std.testing.expectError(error.InvalidTupleSize, view.update_xmax(slot, 1));
}

test "SlottedView: many small inserts do not corrupt earlier slots" {
    var raw = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw, true);

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:0>4}", .{i}) catch unreachable;
        _ = try view.insert_tuple(null, s);
    }

    i = 0;
    while (i < 100) : (i += 1) {
        var buf: [4]u8 = undefined;
        const expected = std.fmt.bufPrint(&buf, "{d:0>4}", .{i}) catch unreachable;
        const got = view.get_tuple(@intCast(i)).?;
        try std.testing.expectEqualStrings(expected, got);
    }
}
