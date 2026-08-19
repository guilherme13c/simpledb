const std = @import("std");
const ast = @import("../ast.zig");
const dupe_value = @import("../executor.zig").dupe_value;
const InMemoryTable = @import("../../storage/in_memory_table.zig").InMemoryTable;

pub const InMemoryScanExecutor = struct {
    table: *InMemoryTable,
    allocator: std.mem.Allocator,
    cursor: usize = 0,

    pub fn open(self: *@This()) !void {
        self.cursor = 0;
    }

    pub fn next(self: *@This()) !?[]ast.Value {
        if (self.cursor < self.table.tuples.items.len) {
            const original = self.table.tuples.items[self.cursor];
            self.cursor += 1;
            
            var duped = try self.allocator.alloc(ast.Value, original.len);
            for (original, 0..) |v, i| {
                duped[i] = try dupe_value(self.allocator, v);
            }
            return duped;
        }
        return null;
    }

    pub fn close(self: *@This()) void {
        _ = self;
    }
};
