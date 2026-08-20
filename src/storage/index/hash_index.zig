const std = @import("std");

pub const HashIndex = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, std.ArrayList(u64)),

    pub fn init(allocator: std.mem.Allocator) HashIndex {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
        };
    }

    pub fn deinit(self: *HashIndex) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.deinit(self.allocator);
        }
        self.map.deinit();
    }

    pub fn insert(self: *HashIndex, key: u64, rid: u64) !void {
        const res = try self.map.getOrPut(key);
        if (!res.found_existing) {
            res.value_ptr.* = std.ArrayList(u64).empty;
        }
        try res.value_ptr.*.append(self.allocator, rid);
    }

    pub fn delete(self: *HashIndex, key: u64, rid: u64) void {
        if (self.map.getPtr(key)) |list| {
            for (list.items, 0..) |item, i| {
                if (item == rid) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator);
                _ = self.map.remove(key);
            }
        }
    }

    pub fn search(self: *HashIndex, allocator: std.mem.Allocator, key: u64) ![]u64 {
        if (self.map.get(key)) |list| {
            const result = try allocator.alloc(u64, list.items.len);
            @memcpy(result, list.items);
            return result;
        }
        return try allocator.alloc(u64, 0);
    }
};
