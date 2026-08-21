const std = @import("std");

pub const Edge = struct { waiting: u32, holding: u32 };

pub const GlobalWFG = struct {
    allocator: std.mem.Allocator,
    edges: std.ArrayList(Edge),

    pub fn init(allocator: std.mem.Allocator) GlobalWFG {
        return .{
            .allocator = allocator,
            .edges = std.ArrayList(Edge).empty,
        };
    }

    pub fn deinit(self: *GlobalWFG) void {
        self.edges.deinit(self.allocator);
    }

    pub fn add_edge(self: *GlobalWFG, waiting: u32, holding: u32) !void {
        for (self.edges.items) |e| {
            if (e.waiting == waiting and e.holding == holding) return;
        }
        try self.edges.append(self.allocator, .{ .waiting = waiting, .holding = holding });
    }

    pub fn detect_cycle(self: *GlobalWFG) ?u32 {
        var visited = std.AutoHashMap(u32, bool).init(self.allocator);
        defer visited.deinit();
        var stack = std.AutoHashMap(u32, bool).init(self.allocator);
        defer stack.deinit();

        var nodes = std.AutoHashMap(u32, void).init(self.allocator);
        defer nodes.deinit();
        for (self.edges.items) |e| {
            nodes.put(e.waiting, {}) catch {};
            nodes.put(e.holding, {}) catch {};
        }

        var it = nodes.keyIterator();
        while (it.next()) |node| {
            if (self.dfs(node.*, &visited, &stack)) |cycle_txn| {
                return cycle_txn;
            }
        }
        return null;
    }

    fn dfs(self: *GlobalWFG, node: u32, visited: *std.AutoHashMap(u32, bool), stack: *std.AutoHashMap(u32, bool)) ?u32 {
        if (stack.contains(node)) return node;
        if (visited.contains(node)) return null;

        visited.put(node, true) catch return null;
        stack.put(node, true) catch return null;

        for (self.edges.items) |e| {
            if (e.waiting == node) {
                if (self.dfs(e.holding, visited, stack)) |cycle_txn| {
                    return @max(node, cycle_txn);
                }
            }
        }

        _ = stack.remove(node);
        return null;
    }
};
