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

// ─── Insert ──────────────────────────────────────────────────────────────────

/// InsertExecutor implements the execution logic for the InsertExecutor operator.
pub const InsertExecutor = struct {
    table: *Table,
    values: []const ast.Value,
    txn_ctx: ?*TransactionContext,
    allocator: std.mem.Allocator,
    executed: bool = false,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *InsertExecutor) !void {
        self.executed = false;
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *InsertExecutor) !?[]ast.Value {
        if (self.executed) return null;

        if (self.table.schema.len == 0) {
            if (self.values.len != 2) return error.InvalidValuesForLegacyTable;
            const key = self.values[0].int;
            const value = self.values[1].varchar;
            _ = try self.table.insert(self.txn_ctx, key, value);
        } else {
            if (self.values.len == 0 or self.values[0] != .int) return error.MissingPrimaryKey;
            const key = self.values[0].int;
            const data = try self.table.serialize_tuple(self.allocator, self.values);
            defer self.allocator.free(data);
            _ = try self.table.insert(self.txn_ctx, key, data);
        }

        self.executed = true;
        return null;
    }
};

