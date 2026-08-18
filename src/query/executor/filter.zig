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

// ─── Filter ──────────────────────────────────────────────────────────────────

/// FilterExecutor implements the execution logic for the FilterExecutor operator.
pub const FilterExecutor = struct {
    child: Executor,
    expression: ast.Expression,
    schema: []const ast.ColumnDef,
    allocator: std.mem.Allocator,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *FilterExecutor) !void {
        try self.child.open();
    }

    /// Cleans up any resources or state allocated by the executor.
    pub fn close(self: *FilterExecutor) void {
        self.child.close();
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *FilterExecutor) !?[]ast.Value {
        while (try self.child.next()) |tuple| {
            if (evaluate_expression(self.expression, tuple, self.schema)) {
                return tuple;
            }
            free_tuple(self.allocator, tuple);
        }
        return null;
    }
};

