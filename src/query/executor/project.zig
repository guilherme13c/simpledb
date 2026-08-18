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

// ─── Project ─────────────────────────────────────────────────────────────────

/// ProjectExecutor implements the execution logic for the ProjectExecutor operator.
pub const ProjectExecutor = struct {
    child: Executor,
    column_indices: []usize,
    allocator: std.mem.Allocator,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *ProjectExecutor) !void {
        try self.child.open();
    }

    /// Cleans up any resources or state allocated by the executor.
    pub fn close(self: *ProjectExecutor) void {
        self.child.close();
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *ProjectExecutor) !?[]ast.Value {
        if (try self.child.next()) |tuple| {
            defer free_tuple(self.allocator, tuple);

            var new_tuple = try self.allocator.alloc(ast.Value, self.column_indices.len);
            for (self.column_indices, 0..) |col_idx, out_idx| {
                if (col_idx < tuple.len) {
                    new_tuple[out_idx] = try dupe_value(self.allocator, tuple[col_idx]);
                } else {
                    new_tuple[out_idx] = .{ .int = 0 }; // Fallback
                }
            }
            return new_tuple;
        }
        return null;
    }
};

