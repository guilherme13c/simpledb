const std = @import("std");
const ast = @import("../ast.zig");
const Table = @import("../../storage/table.zig").Table;
const Catalog = @import("../../storage/catalog.zig").Catalog;
const TransactionContext = @import("../../storage/wal/transaction.zig").TransactionContext;
const Executor = @import("../executor.zig").Executor;
const resolve_column = @import("../executor.zig").resolve_column;

pub const UpdateExecutor = struct {
    table: *Table,
    child: *Executor,
    column_name: []const u8,
    new_value: ast.Value,
    txn_ctx: ?*TransactionContext = null,
    allocator: std.mem.Allocator,
    executed: bool = false,

    pub fn open(self: *UpdateExecutor) !void {
        self.executed = false;
        try self.child.open();
    }

    pub fn next(self: *UpdateExecutor) !?[]ast.Value {
        if (self.executed) return null;
        
        const col_idx = resolve_column(self.table.schema, self.column_name) orelse return error.SchemaMismatch;

        while (try self.child.next()) |tuple| {
            if (tuple.len == 0 or tuple[0] != .int) return error.MissingPrimaryKey;
            const key = tuple[0].int;

            var new_tuple = try self.allocator.alloc(ast.Value, tuple.len);
            for (tuple, 0..) |v, i| {
                if (i == col_idx) {
                    new_tuple[i] = try @import("../executor.zig").dupe_value(self.allocator, self.new_value);
                } else {
                    new_tuple[i] = try @import("../executor.zig").dupe_value(self.allocator, v);
                }
            }

            const new_data = try self.table.serialize_tuple(self.allocator, new_tuple);
            defer self.allocator.free(new_data);

            try self.table.delete(self.txn_ctx, key);
            const new_key = new_tuple[0].int;
            _ = try self.table.insert(self.txn_ctx, new_key, new_data);
            
            @import("../executor.zig").free_tuple(self.allocator, new_tuple);
            @import("../executor.zig").free_tuple(self.allocator, tuple);
        }

        self.executed = true;
        return null;
    }

    pub fn close(self: *UpdateExecutor) void {
        self.child.close();
    }
};
