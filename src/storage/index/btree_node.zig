const std = @import("std");
const page = @import("../page/page.zig");

pub const NodeType = enum(u1) {
    internal = 0,
    leaf = 1,
};

pub const BTreeMetadata = packed struct(u38) {
    node_type: NodeType,
    num_keys: u13,
    next_leaf: u24 = 0,
};

pub const BTreeNodeView = struct {
    raw: *page.Page,

    pub fn get_meta(self: *const BTreeNodeView) BTreeMetadata {
        return @bitCast(self.raw.header.special);
    }

    pub fn set_meta(self: *BTreeNodeView, meta: BTreeMetadata) void {
        self.raw.header.special = @bitCast(meta);
    }

    pub fn is_safe_for_insert(self: *const BTreeNodeView) bool {
        const meta = self.get_meta();
        if (meta.node_type == .leaf) {
            const capacity = page.content_length / @sizeOf(KeyValue);
            return meta.num_keys < capacity;
        } else {
            const capacity = (page.content_length - 8) / @sizeOf(InternalEntry);
            return meta.num_keys < capacity;
        }
    }

    pub fn is_safe_for_delete(self: *const BTreeNodeView) bool {
        const meta = self.get_meta();
        if (meta.node_type == .leaf) {
            const capacity = page.content_length / @sizeOf(KeyValue);
            return meta.num_keys > (capacity / 2);
        } else {
            const capacity = (page.content_length - 8) / @sizeOf(InternalEntry);
            return meta.num_keys > (capacity / 2);
        }
    }

    pub fn init(raw: *page.Page, node_type: NodeType) BTreeNodeView {
        var view = BTreeNodeView{ .raw = raw };
        view.set_meta(.{
            .node_type = node_type,
            .num_keys = 0,
        });
        return view;
    }

    pub const KeyValue = packed struct {
        key: u64,
        value: u64,
    };

    pub fn get_leaf_elements(self: *BTreeNodeView) []align(1) KeyValue {
        const meta = self.get_meta();
        const capacity = page.content_length / @sizeOf(KeyValue);
        const ptr = @as(*align(1) [capacity]KeyValue, @ptrCast(&self.raw.content));

        return ptr[0..meta.num_keys];
    }

    pub fn leaf_search(self: *BTreeNodeView, key: u64) ?u64 {
        const elements = self.get_leaf_elements();

        var left: usize = 0;
        var right: usize = elements.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (elements[mid].key == key) {
                return elements[mid].value;
            } else if (elements[mid].key < key) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return null;
    }

    pub fn leaf_insert(self: *BTreeNodeView, key: u64, value: u64) !void {
        var meta = self.get_meta();
        const capacity = page.content_length / @sizeOf(KeyValue);

        if (meta.num_keys >= capacity) {
            return error.NodeFull;
        }

        const ptr = @as(*align(1) [capacity]KeyValue, @ptrCast(&self.raw.content));
        
        var left: usize = 0;
        var right: usize = meta.num_keys;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (ptr[mid].key < key) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        const insert_idx = left;

        const dest_bytes = std.mem.sliceAsBytes(ptr[insert_idx + 1 .. meta.num_keys + 1]);
        const src_bytes = std.mem.sliceAsBytes(ptr[insert_idx .. meta.num_keys]);
        std.mem.copyBackwards(u8, dest_bytes, src_bytes);

        ptr[insert_idx] = .{
            .key = key,
            .value = value,
        };

        meta.num_keys += 1;
        self.set_meta(meta);
    }

    pub fn leaf_delete(self: *BTreeNodeView, key: u64) !void {
        var meta = self.get_meta();
        const capacity = page.content_length / @sizeOf(KeyValue);
        const ptr = @as(*align(1) [capacity]KeyValue, @ptrCast(&self.raw.content));

        var left: usize = 0;
        var right: usize = meta.num_keys;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (ptr[mid].key < key) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        if (left < meta.num_keys and ptr[left].key == key) {
            const idx = left;
            const dest_bytes = std.mem.sliceAsBytes(ptr[idx .. meta.num_keys - 1]);
            const src_bytes = std.mem.sliceAsBytes(ptr[idx + 1 .. meta.num_keys]);
            std.mem.copyForwards(u8, dest_bytes, src_bytes);
            meta.num_keys -= 1;
            self.set_meta(meta);
        } else {
            return error.KeyNotFound;
        }
    }

    pub fn split_leaf(self: *BTreeNodeView, new_node: *BTreeNodeView, new_node_id: u32) void {
        var meta = self.get_meta();
        var new_meta = new_node.get_meta();

        const capacity = page.content_length / @sizeOf(KeyValue);
        const ptr = @as(*[capacity]KeyValue, @ptrCast(@alignCast(&self.raw.content)));
        const new_ptr = @as(*[capacity]KeyValue, @ptrCast(@alignCast(&new_node.raw.content)));

        const mid = meta.num_keys / 2;
        const keys_to_move = meta.num_keys - mid;

        @memcpy(new_ptr[0..keys_to_move], ptr[mid..meta.num_keys]);

        meta.num_keys = mid;
        new_meta.num_keys = keys_to_move;
        
        new_meta.next_leaf = meta.next_leaf;
        meta.next_leaf = @intCast(new_node_id);

        self.set_meta(meta);
        new_node.set_meta(new_meta);
    }

    pub fn merge_leaf(self: *BTreeNodeView, right_sibling: *BTreeNodeView) void {
        var meta = self.get_meta();
        var right_meta = right_sibling.get_meta();

        const capacity = page.content_length / @sizeOf(KeyValue);
        const ptr = @as(*[capacity]KeyValue, @ptrCast(@alignCast(&self.raw.content)));
        const right_ptr = @as(*[capacity]KeyValue, @ptrCast(@alignCast(&right_sibling.raw.content)));

        @memcpy(ptr[meta.num_keys .. meta.num_keys + right_meta.num_keys], right_ptr[0..right_meta.num_keys]);

        meta.num_keys += right_meta.num_keys;
        meta.next_leaf = right_meta.next_leaf;

        right_meta.num_keys = 0;

        self.set_meta(meta);
        right_sibling.set_meta(right_meta);
    }

    pub const InternalEntry = packed struct {
        key: u64,
        right_child: u32,
        _padding: u32 = 0, // Pad to 16 bytes for alignment
    };

    pub fn get_leftmost_child(self: *const BTreeNodeView) u32 {
        const ptr = @as(*const u32, @ptrCast(@alignCast(&self.raw.content[0])));
        return ptr.*;
    }

    pub fn set_leftmost_child(self: *BTreeNodeView, child_page_id: u32) void {
        const ptr = @as(*u32, @ptrCast(@alignCast(&self.raw.content[0])));
        ptr.* = child_page_id;
    }

    pub fn get_internal_elements(self: *BTreeNodeView) []align(1) InternalEntry {
        const meta = self.get_meta();
        const capacity = (page.content_length - 8) / @sizeOf(InternalEntry);
        const ptr = @as(*align(1) [capacity]InternalEntry, @ptrCast(&self.raw.content[8]));

        return ptr[0..meta.num_keys];
    }

    pub fn internal_search(self: *BTreeNodeView, key: u64) u32 {
        const elements = self.get_internal_elements();

        if (elements.len == 0) return self.get_leftmost_child();

        var left: usize = 0;
        var right: usize = elements.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (elements[mid].key <= key) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        // If left == 0, the key is strictly smaller than our very first key.
        if (left == 0) {
            return self.get_leftmost_child();
        }

        return elements[left - 1].right_child;
    }

    pub fn internal_insert(self: *BTreeNodeView, key: u64, right_child: u32) !void {
        var meta = self.get_meta();
        const capacity = (page.content_length - 8) / @sizeOf(InternalEntry);

        if (meta.num_keys >= capacity) {
            return error.NodeFull;
        }

        const ptr = @as(*align(1) [capacity]InternalEntry, @ptrCast(&self.raw.content[8]));

        var left: usize = 0;
        var right: usize = meta.num_keys;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (ptr[mid].key < key) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        const insert_idx = left;

        const dest_bytes = std.mem.sliceAsBytes(ptr[insert_idx + 1 .. meta.num_keys + 1]);
        const src_bytes = std.mem.sliceAsBytes(ptr[insert_idx .. meta.num_keys]);
        std.mem.copyBackwards(u8, dest_bytes, src_bytes);

        ptr[insert_idx] = .{ .key = key, .right_child = right_child };

        meta.num_keys += 1;
        self.set_meta(meta);
    }

    pub fn internal_delete(self: *BTreeNodeView, child_id_to_remove: u32) !void {
        var meta = self.get_meta();
        const capacity = (page.content_length - 8) / @sizeOf(InternalEntry);
        const ptr = @as(*align(1) [capacity]InternalEntry, @ptrCast(&self.raw.content[8]));

        if (self.get_leftmost_child() == child_id_to_remove) {
            if (meta.num_keys == 0) return error.KeyNotFound;
            self.set_leftmost_child(ptr[0].right_child);
            const dest_bytes = std.mem.sliceAsBytes(ptr[0 .. meta.num_keys - 1]);
            const src_bytes = std.mem.sliceAsBytes(ptr[1 .. meta.num_keys]);
            std.mem.copyForwards(u8, dest_bytes, src_bytes);
            meta.num_keys -= 1;
            self.set_meta(meta);
            return;
        }

        for (0..meta.num_keys) |i| {
            if (ptr[i].right_child == child_id_to_remove) {
                const dest_bytes = std.mem.sliceAsBytes(ptr[i .. meta.num_keys - 1]);
                const src_bytes = std.mem.sliceAsBytes(ptr[i + 1 .. meta.num_keys]);
                std.mem.copyForwards(u8, dest_bytes, src_bytes);
                meta.num_keys -= 1;
                self.set_meta(meta);
                return;
            }
        }
        return error.KeyNotFound;
    }

    pub fn split_internal(self: *BTreeNodeView, new_node: *BTreeNodeView) u64 {
        var meta = self.get_meta();
        var new_meta = new_node.get_meta();

        const capacity = (page.content_length - 8) / @sizeOf(InternalEntry);
        const ptr = @as(*align(1) [capacity]InternalEntry, @ptrCast(&self.raw.content[8]));
        const new_ptr = @as(*align(1) [capacity]InternalEntry, @ptrCast(&new_node.raw.content[8]));

        const mid = meta.num_keys / 2;

        const push_up_key = ptr[mid].key;

        new_node.set_leftmost_child(ptr[mid].right_child);

        const keys_to_move = meta.num_keys - (mid + 1);
        @memcpy(new_ptr[0..keys_to_move], ptr[mid + 1 .. meta.num_keys]);

        meta.num_keys = mid;
        new_meta.num_keys = keys_to_move;

        self.set_meta(meta);
        new_node.set_meta(new_meta);

        return push_up_key;
    }

    pub fn merge_internal(self: *BTreeNodeView, right_sibling: *BTreeNodeView, parent_key: u64) void {
        var meta = self.get_meta();
        var right_meta = right_sibling.get_meta();

        const capacity = (page.content_length - 8) / @sizeOf(InternalEntry);
        const ptr = @as(*align(1) [capacity]InternalEntry, @ptrCast(&self.raw.content[8]));
        const right_ptr = @as(*align(1) [capacity]InternalEntry, @ptrCast(&right_sibling.raw.content[8]));

        ptr[meta.num_keys] = .{
            .key = parent_key,
            .right_child = right_sibling.get_leftmost_child(),
        };
        meta.num_keys += 1;

        @memcpy(ptr[meta.num_keys .. meta.num_keys + right_meta.num_keys], right_ptr[0..right_meta.num_keys]);

        meta.num_keys += right_meta.num_keys;
        right_meta.num_keys = 0;

        self.set_meta(meta);
        right_sibling.set_meta(right_meta);
    }
};

test "BTreeNodeView leaf operations" {
    var raw_page = std.mem.zeroes(page.Page);
    var node = BTreeNodeView.init(&raw_page, .leaf);

    try node.leaf_insert(10, 100);
    try node.leaf_insert(5, 50);
    try node.leaf_insert(20, 200);

    const meta = node.get_meta();
    try std.testing.expectEqual(@as(u16, 3), meta.num_keys);
    try std.testing.expectEqual(.leaf, meta.node_type);

    try std.testing.expectEqual(@as(u64, 50), node.leaf_search(5).?);
    try std.testing.expectEqual(@as(u64, 100), node.leaf_search(10).?);
    try std.testing.expectEqual(@as(u64, 200), node.leaf_search(20).?);
    try std.testing.expectEqual(@as(?u64, null), node.leaf_search(15));
}

test "BTreeNodeView leaf split" {
    var raw_page1 = std.mem.zeroes(page.Page);
    var node1 = BTreeNodeView.init(&raw_page1, .leaf);

    // Fill the node
    const capacity = page.content_length / @sizeOf(BTreeNodeView.KeyValue);
    var i: u16 = 0;
    while (i < capacity) : (i += 1) {
        try node1.leaf_insert(i, i * 10);
    }

    var raw_page2 = std.mem.zeroes(page.Page);
    var node2 = BTreeNodeView.init(&raw_page2, .leaf);

    node1.split_leaf(&node2, 999);

    const meta1 = node1.get_meta();
    const meta2 = node2.get_meta();

    try std.testing.expectEqual(@as(u16, capacity / 2), meta1.num_keys);
    try std.testing.expectEqual(@as(u16, capacity - (capacity / 2)), meta2.num_keys);
    try std.testing.expectEqual(@as(u24, 999), meta1.next_leaf);
}

test "BTreeNodeView internal operations" {
    var raw_page = std.mem.zeroes(page.Page);
    var node = BTreeNodeView.init(&raw_page, .internal);

    node.set_leftmost_child(1);
    try node.internal_insert(10, 2);
    try node.internal_insert(20, 3);
    try node.internal_insert(5, 4);

    // Elements should be: [5: 4], [10: 2], [20: 3]
    try std.testing.expectEqual(@as(u32, 1), node.internal_search(1));
    try std.testing.expectEqual(@as(u32, 4), node.internal_search(6));
    try std.testing.expectEqual(@as(u32, 2), node.internal_search(15));
    try std.testing.expectEqual(@as(u32, 3), node.internal_search(25));
}

test "BTreeNodeView leaf merge" {
    var raw_page1 = std.mem.zeroes(page.Page);
    var node1 = BTreeNodeView.init(&raw_page1, .leaf);
    try node1.leaf_insert(1, 10);
    try node1.leaf_insert(2, 20);

    var raw_page2 = std.mem.zeroes(page.Page);
    var node2 = BTreeNodeView.init(&raw_page2, .leaf);
    try node2.leaf_insert(3, 30);
    try node2.leaf_insert(4, 40);
    
    // Simulate next leaf linkage
    var meta1 = node1.get_meta();
    meta1.next_leaf = 100; // random id for node2
    node1.set_meta(meta1);
    
    var meta2 = node2.get_meta();
    meta2.next_leaf = 200; // random id for what comes after node2
    node2.set_meta(meta2);

    node1.merge_leaf(&node2);

    const merged_meta1 = node1.get_meta();
    const merged_meta2 = node2.get_meta();

    try std.testing.expectEqual(@as(u13, 4), merged_meta1.num_keys);
    try std.testing.expectEqual(@as(u13, 0), merged_meta2.num_keys);
    try std.testing.expectEqual(@as(u24, 200), merged_meta1.next_leaf);

    const elements = node1.get_leaf_elements();
    try std.testing.expectEqual(@as(u64, 1), elements[0].key);
    try std.testing.expectEqual(@as(u64, 2), elements[1].key);
    try std.testing.expectEqual(@as(u64, 3), elements[2].key);
    try std.testing.expectEqual(@as(u64, 4), elements[3].key);
}

test "BTreeNodeView internal merge" {
    var raw_page1 = std.mem.zeroes(page.Page);
    var node1 = BTreeNodeView.init(&raw_page1, .internal);
    node1.set_leftmost_child(10);
    try node1.internal_insert(5, 20);
    try node1.internal_insert(15, 30);

    var raw_page2 = std.mem.zeroes(page.Page);
    var node2 = BTreeNodeView.init(&raw_page2, .internal);
    node2.set_leftmost_child(40);
    try node2.internal_insert(35, 50);
    try node2.internal_insert(45, 60);

    // merge node2 into node1. The parent key was 25.
    node1.merge_internal(&node2, 25);

    const merged_meta1 = node1.get_meta();
    const merged_meta2 = node2.get_meta();

    try std.testing.expectEqual(@as(u13, 5), merged_meta1.num_keys);
    try std.testing.expectEqual(@as(u13, 0), merged_meta2.num_keys);

    const elements = node1.get_internal_elements();
    // Expected keys: 5, 15, 25 (from parent), 35, 45
    // Expected right children: 20, 30, 40 (from node2 leftmost), 50, 60
    try std.testing.expectEqual(@as(u64, 5), elements[0].key);
    try std.testing.expectEqual(@as(u32, 20), elements[0].right_child);

    try std.testing.expectEqual(@as(u64, 15), elements[1].key);
    try std.testing.expectEqual(@as(u32, 30), elements[1].right_child);

    try std.testing.expectEqual(@as(u64, 25), elements[2].key);
    try std.testing.expectEqual(@as(u32, 40), elements[2].right_child);

    try std.testing.expectEqual(@as(u64, 35), elements[3].key);
    try std.testing.expectEqual(@as(u32, 50), elements[3].right_child);

    try std.testing.expectEqual(@as(u64, 45), elements[4].key);
    try std.testing.expectEqual(@as(u32, 60), elements[4].right_child);
}
