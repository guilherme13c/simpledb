const std = @import("std");
const page = @import("page.zig");

pub const Slot = packed struct {
    offset: u13,
    length: u13,
};

pub const SlottedView = struct {
    raw: *page.Page,

    pub fn init(raw: *page.Page, is_new: bool) SlottedView {
        if (is_new) {
            raw.header.lower = 0;
            raw.header.upper = page.content_length;
        }
        return .{ .raw = raw };
    }

    pub fn insert_tuple(self: *SlottedView, header: ?[]const u8, data: []const u8) !u16 {
        const slot_size = @sizeOf(Slot);
        const header_len = if (header) |h| h.len else 0;
        const space_needed = header_len + data.len + slot_size;

        if (self.raw.header.upper < self.raw.header.lower + space_needed) {
            return error.OutOfSpace;
        }

        // Allocate space for data from the top (upper)
        self.raw.header.upper -= @intCast(header_len + data.len);
        const data_start = self.raw.header.upper;
        
        if (header) |h| {
            @memcpy(self.raw.content[data_start .. data_start + h.len], h);
            @memcpy(self.raw.content[data_start + h.len .. data_start + h.len + data.len], data);
        } else {
            @memcpy(self.raw.content[data_start .. data_start + data.len], data);
        }

        // Allocate space for the slot from the bottom (lower)
        const slot_offset = self.raw.header.lower;
        self.raw.header.lower += slot_size;

        // Use unaligned pointer cast just in case the content array isn't perfectly aligned
        const slot_ptr = @as(*align(1) Slot, @ptrCast(&self.raw.content[slot_offset]));
        slot_ptr.* = .{
            .offset = @intCast(data_start),
            .length = @intCast(header_len + data.len),
        };

        return @intCast(slot_offset / slot_size);
    }

    pub fn get_tuple(self: *SlottedView, slot_id: u16) ?[]const u8 {
        const slot_size = 4;
        const slot_offset = slot_id * slot_size;

        if (slot_offset >= self.raw.header.lower) return null;

        const slot_ptr = @as(*align(1) const Slot, @ptrCast(&self.raw.content[slot_offset]));

        const start = slot_ptr.offset;
        const end = start + slot_ptr.length;

        return self.raw.content[start..end];
    }

    pub fn update_xmax(self: *SlottedView, slot_id: u16, xmax: u32) !void {
        const slot_size = 4;
        const slot_offset = slot_id * slot_size;

        if (slot_offset >= self.raw.header.lower) return error.InvalidSlot;

        const slot_ptr = @as(*align(1) const Slot, @ptrCast(&self.raw.content[slot_offset]));
        const start = slot_ptr.offset;
        
        if (slot_ptr.length < 8) return error.InvalidTupleSize;

        std.mem.writeInt(u32, self.raw.content[start + 4 .. start + 8][0..4], xmax, .little);
    }
};

test "SlottedView insert and get" {
    var raw_page = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw_page, true);

    const slot0 = try view.insert_tuple(null, "hello");
    const slot1 = try view.insert_tuple(null, "world");

    try std.testing.expectEqual(@as(u16, 0), slot0);
    try std.testing.expectEqual(@as(u16, 1), slot1);

    const data0 = view.get_tuple(slot0).?;
    try std.testing.expectEqualStrings("hello", data0);

    const data1 = view.get_tuple(slot1).?;
    try std.testing.expectEqualStrings("world", data1);
}

test "SlottedView out of space" {
    var raw_page = std.mem.zeroes(page.Page);
    var view = SlottedView.init(&raw_page, true);

    // Create a huge payload that occupies almost all space
    const huge_payload = [_]u8{ 'A' } ** (page.content_length - 10);
    
    _ = try view.insert_tuple(null, &huge_payload);

    // Next insert should fail due to lack of space
    const err = view.insert_tuple(null, "toolarge");
    try std.testing.expectError(error.OutOfSpace, err);
}
