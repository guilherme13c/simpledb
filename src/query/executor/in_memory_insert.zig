const std = @import("std");
const ast = @import("../ast.zig");
const InMemoryTable = @import("../../storage/in_memory_table.zig").InMemoryTable;
const Executor = @import("../executor.zig").Executor;

pub const InMemoryInsertExecutor = struct {
    table: *InMemoryTable,
    child: *Executor,
    allocator: std.mem.Allocator,

    pub fn open(self: *@This()) !void {
        try self.child.open();
    }

    pub fn next(self: *@This()) !?[]ast.Value {
        var inserted: u64 = 0;
        while (try self.child.next()) |tuple| {
            defer @import("../executor.zig").free_tuple(self.allocator, tuple);
            try self.table.insert_tuple(tuple);
            inserted += 1;
        }
        var res = try self.allocator.alloc(ast.Value, 1);
        res[0] = .{ .int = @intCast(inserted) };
        return res;
    }

    pub fn close(self: *@This()) void {
        self.child.close();
    }
};
