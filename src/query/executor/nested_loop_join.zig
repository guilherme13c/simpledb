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

// ─── NestedLoopJoin ──────────────────────────────────────────────────────────

/// NestedLoopJoinExecutor implements the execution logic for the NestedLoopJoinExecutor operator.
pub const NestedLoopJoinExecutor = struct {
    left_child: *Executor,
    right_child: *Executor,
    join_condition: ast.Expression,
    join_type: ast.JoinType,
    left_schema: []const ast.ColumnDef,
    right_schema: []const ast.ColumnDef,
    allocator: std.mem.Allocator,

    right_tuples: std.ArrayList([]ast.Value) = undefined,
    right_matched: std.ArrayList(bool) = undefined,
    current_left_tuple: ?[]ast.Value = null,
    right_idx: usize = 0,
    initialized: bool = false,
    matched_any_right: bool = false,
    yielding_right_unmatched: bool = false,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *NestedLoopJoinExecutor) !void {
        try self.left_child.open();
        try self.right_child.open();
        defer self.right_child.close();

        self.right_tuples = std.ArrayList([]ast.Value).empty;
        self.right_matched = std.ArrayList(bool).empty;
        while (try self.right_child.next()) |tuple| {
            var duped = try self.allocator.alloc(ast.Value, tuple.len);
            for (tuple, 0..) |v, i| {
                duped[i] = try dupe_value(self.allocator, v);
            }
            free_tuple(self.allocator, tuple);
            try self.right_tuples.append(self.allocator, duped);
            try self.right_matched.append(self.allocator, false);
        }
        self.current_left_tuple = try self.left_child.next();
        self.right_idx = 0;
        self.matched_any_right = false;
        self.yielding_right_unmatched = false;
        self.initialized = true;
    }

    /// Cleans up any resources or state allocated by the executor.
    pub fn close(self: *NestedLoopJoinExecutor) void {
        if (!self.initialized) return;
        self.left_child.close();
        for (self.right_tuples.items) |tuple| {
            free_tuple(self.allocator, tuple);
        }
        self.right_tuples.deinit(self.allocator);
        self.right_matched.deinit(self.allocator);
        if (self.current_left_tuple) |t| free_tuple(self.allocator, t);
        self.initialized = false;
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *NestedLoopJoinExecutor) !?[]ast.Value {
        if (self.yielding_right_unmatched) {
            return try self.yield_unmatched_right();
        }

        while (self.current_left_tuple != null) {
            const left_tuple = self.current_left_tuple.?;

            while (self.right_idx < self.right_tuples.items.len) {
                const right_tuple = self.right_tuples.items[self.right_idx];
                const current_right_idx = self.right_idx;
                self.right_idx += 1;

                if (try evaluate_join_expression(self.join_condition, left_tuple, self.left_schema, right_tuple, self.right_schema)) {
                    self.matched_any_right = true;
                    self.right_matched.items[current_right_idx] = true;
                    var joined = try self.allocator.alloc(ast.Value, left_tuple.len + right_tuple.len);
                    for (left_tuple, 0..) |v, i| {
                        joined[i] = try dupe_value(self.allocator, v);
                    }
                    for (right_tuple, 0..) |v, i| {
                        joined[left_tuple.len + i] = try dupe_value(self.allocator, v);
                    }
                    return joined;
                }
            }

            // If we finished right table and no matches, and it's a LEFT or FULL JOIN, emit padded tuple
            if ((self.join_type == .left or self.join_type == .full) and !self.matched_any_right) {
                var joined = try self.allocator.alloc(ast.Value, left_tuple.len + self.right_schema.len);
                for (left_tuple, 0..) |v, i| {
                    joined[i] = try dupe_value(self.allocator, v);
                }
                for (0..self.right_schema.len) |i| {
                    joined[left_tuple.len + i] = .{ .null_val = {} };
                }
                
                free_tuple(self.allocator, left_tuple);
                self.current_left_tuple = try self.left_child.next();
                self.right_idx = 0;
                self.matched_any_right = false;
                return joined;
            }

            free_tuple(self.allocator, left_tuple);
            self.current_left_tuple = try self.left_child.next();
            self.right_idx = 0;
            self.matched_any_right = false;
        }

        // Finished all left tuples.
        if (self.join_type == .right or self.join_type == .full) {
            self.yielding_right_unmatched = true;
            self.right_idx = 0; // reuse right_idx for iterating over unmatched
            return try self.yield_unmatched_right();
        }

        return null;
    }

    fn yield_unmatched_right(self: *NestedLoopJoinExecutor) !?[]ast.Value {
        while (self.right_idx < self.right_tuples.items.len) {
            const right_tuple = self.right_tuples.items[self.right_idx];
            const is_matched = self.right_matched.items[self.right_idx];
            self.right_idx += 1;

            if (!is_matched) {
                var joined = try self.allocator.alloc(ast.Value, self.left_schema.len + right_tuple.len);
                for (0..self.left_schema.len) |i| {
                    joined[i] = .{ .null_val = {} };
                }
                for (right_tuple, 0..) |v, i| {
                    joined[self.left_schema.len + i] = try dupe_value(self.allocator, v);
                }
                return joined;
            }
        }
        return null;
    }
};

