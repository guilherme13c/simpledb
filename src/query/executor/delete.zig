const std = @import("std");
const ast = @import("../ast.zig");
const Table = @import("../../storage/table.zig").Table;
const Catalog = @import("../../storage/catalog.zig").Catalog;
const TransactionContext = @import("../../storage/wal/transaction.zig").TransactionContext;
const Executor = @import("../executor.zig").Executor;
const resolve_column = @import("../executor.zig").resolve_column;
const evaluate_expression = @import("../executor.zig").evaluate_expression;
const compare_values = @import("../executor.zig").compare_values;
const evaluate_join_expression = @import("../executor.zig").evaluate_join_expression;
const dupe_value = @import("../executor.zig").dupe_value;
const free_tuple = @import("../executor.zig").free_tuple;
const ValueContext = @import("../executor.zig").ValueContext;

// ─── Delete ──────────────────────────────────────────────────────────────────

/// DeleteExecutor implements the execution logic for the DeleteExecutor operator.
pub const DeleteExecutor = struct {
    table: *Table,
    child: *Executor,
    txn_ctx: ?*TransactionContext,
    allocator: std.mem.Allocator,
    executed: bool = false,

    pub fn open(self: *DeleteExecutor) !void {
        self.executed = false;
        try self.child.open();
    }

    pub fn next(self: *DeleteExecutor) !?[]ast.Value {
        if (self.executed) return null;

        while (try self.child.next()) |tuple| {
            if (tuple.len == 0 or tuple[0] != .int) return error.MissingPrimaryKey;
            const key = tuple[0].int;

            try self.table.delete(self.txn_ctx, key);
            
            @import("../executor.zig").free_tuple(self.allocator, tuple);
        }

        self.executed = true;
        return null;
    }

    pub fn close(self: *DeleteExecutor) void {
        self.child.close();
    }
};