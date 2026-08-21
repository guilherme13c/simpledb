const std = @import("std");

pub const VirtualNode = struct {
    hash: u64,
    physical_node: []const u8,
};

fn cmpVirtualNode(context: void, a: VirtualNode, b: VirtualNode) bool {
    _ = context;
    return a.hash < b.hash;
}

pub const ConsistentHashRing = struct {
    vnodes: std.ArrayList(VirtualNode),
    allocator: std.mem.Allocator,
    vnodes_per_physical: usize,

    pub fn init(allocator: std.mem.Allocator, vnodes_per_physical: usize) ConsistentHashRing {
        return ConsistentHashRing{
            .vnodes = std.ArrayList(VirtualNode).empty,
            .allocator = allocator,
            .vnodes_per_physical = vnodes_per_physical,
        };
    }

    pub fn deinit(self: *ConsistentHashRing) void {
        for (self.vnodes.items) |vnode| {
            self.allocator.free(vnode.physical_node);
        }
        self.vnodes.deinit(self.allocator);
    }

    pub fn add_node(self: *ConsistentHashRing, node_id: []const u8) !void {
        var buf: [256]u8 = undefined;
        for (0..self.vnodes_per_physical) |i| {
            const vnode_key = try std.fmt.bufPrint(&buf, "{s}#{}", .{ node_id, i });
            const hash = std.hash.Wyhash.hash(0, vnode_key);
            
            const p_node = try self.allocator.dupe(u8, node_id);
            try self.vnodes.append(self.allocator, .{ .hash = hash, .physical_node = p_node });
        }
        std.mem.sortUnstable(VirtualNode, self.vnodes.items, {}, cmpVirtualNode);
    }

    pub fn remove_node(self: *ConsistentHashRing, node_id: []const u8) void {
        var i: usize = 0;
        while (i < self.vnodes.items.len) {
            if (std.mem.eql(u8, self.vnodes.items[i].physical_node, node_id)) {
                self.allocator.free(self.vnodes.items[i].physical_node);
                _ = self.vnodes.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn get_node(self: *const ConsistentHashRing, key: []const u8) ?[]const u8 {
        if (self.vnodes.items.len == 0) return null;
        
        const hash = std.hash.Wyhash.hash(0, key);
        
        var left: usize = 0;
        var right: usize = self.vnodes.items.len;
        
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.vnodes.items[mid].hash < hash) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        
        if (left == self.vnodes.items.len) {
            return self.vnodes.items[0].physical_node; // Wrap around
        }
        
        return self.vnodes.items[left].physical_node;
    }
};

const testing = std.testing;

test "ConsistentHashRing basic routing" {
    var ring = ConsistentHashRing.init(testing.allocator, 3);
    defer ring.deinit();

    try ring.add_node("nodeA");
    try ring.add_node("nodeB");
    try ring.add_node("nodeC");

    const n1 = ring.get_node("user_1");
    try testing.expect(n1 != null);
    
    // Removing nodeB should remap keys correctly
    ring.remove_node("nodeB");
    const n2 = ring.get_node("user_1");
    try testing.expect(n2 != null);
}
