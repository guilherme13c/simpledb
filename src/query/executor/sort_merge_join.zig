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

// ─── SortMergeJoin ────────────────────────────────────────────────────────────

fn lessThanSortMerge(context: usize, lhs: []ast.Value, rhs: []ast.Value) bool {
    const col_idx = context;
    if (col_idx >= lhs.len or col_idx >= rhs.len) return false;
    const l = lhs[col_idx];
    const r = rhs[col_idx];
    return compare_values(l, .lt, r);
}

/// SortMergeJoinExecutor implements the execution logic for the SortMergeJoinExecutor operator.
pub const SortMergeJoinExecutor = struct {
    left_child: *Executor,
    right_child: *Executor,
    left_join_col_idx: usize,
    right_join_col_idx: usize,
    allocator: std.mem.Allocator,

    left_tuples: std.ArrayList([]ast.Value) = undefined,
    right_tuples: std.ArrayList([]ast.Value) = undefined,
    left_idx: usize = 0,
    right_idx: usize = 0,
    match_right_start_idx: ?usize = null,
    initialized: bool = false,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *SortMergeJoinExecutor) !void {
        try self.left_child.open();
        try self.right_child.open();

        self.left_tuples = std.ArrayList([]ast.Value).empty;
        while (try self.left_child.next()) |tuple| {
            var duped = try self.allocator.alloc(ast.Value, tuple.len);
            for (tuple, 0..) |v, i| {
                duped[i] = try dupe_value(self.allocator, v);
            }
            try self.left_tuples.append(self.allocator, duped);
            free_tuple(self.allocator, tuple);
        }
        std.mem.sort([]ast.Value, self.left_tuples.items, self.left_join_col_idx, lessThanSortMerge);

        self.right_tuples = std.ArrayList([]ast.Value).empty;
        while (try self.right_child.next()) |tuple| {
            var duped = try self.allocator.alloc(ast.Value, tuple.len);
            for (tuple, 0..) |v, i| {
                duped[i] = try dupe_value(self.allocator, v);
            }
            try self.right_tuples.append(self.allocator, duped);
            free_tuple(self.allocator, tuple);
        }
        std.mem.sort([]ast.Value, self.right_tuples.items, self.right_join_col_idx, lessThanSortMerge);

        self.left_idx = 0;
        self.right_idx = 0;
        self.match_right_start_idx = null;
        self.initialized = true;
    }

    /// Cleans up any resources or state allocated by the executor.
    pub fn close(self: *SortMergeJoinExecutor) void {
        if (!self.initialized) return;
        self.left_child.close();
        self.right_child.close();

        for (self.left_tuples.items) |tuple| {
            free_tuple(self.allocator, tuple);
        }
        self.left_tuples.deinit(self.allocator);

        for (self.right_tuples.items) |tuple| {
            free_tuple(self.allocator, tuple);
        }
        self.right_tuples.deinit(self.allocator);

        self.initialized = false;
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *SortMergeJoinExecutor) !?[]ast.Value {
        while (self.left_idx < self.left_tuples.items.len) {
            if (self.match_right_start_idx) |start_idx| {
                if (self.right_idx < self.right_tuples.items.len) {
                    const left_tuple = self.left_tuples.items[self.left_idx];
                    const right_tuple = self.right_tuples.items[self.right_idx];
                    const l_val = left_tuple[self.left_join_col_idx];
                    const r_val = right_tuple[self.right_join_col_idx];
                    
                    if (compare_values(l_val, .eq, r_val)) {
                        self.right_idx += 1;
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
                
                const left_tuple = self.left_tuples.items[self.left_idx];
                const l_val = left_tuple[self.left_join_col_idx];
                
                self.left_idx += 1;
                if (self.left_idx < self.left_tuples.items.len) {
                    const next_left = self.left_tuples.items[self.left_idx];
                    const next_l_val = next_left[self.left_join_col_idx];
                    if (compare_values(next_l_val, .eq, l_val)) {
                        self.right_idx = start_idx;
                        continue;
                    }
                }
                self.match_right_start_idx = null;
                continue;
            } else {
                if (self.right_idx >= self.right_tuples.items.len) return null;
                
                const left_tuple = self.left_tuples.items[self.left_idx];
                const right_tuple = self.right_tuples.items[self.right_idx];
                const l_val = left_tuple[self.left_join_col_idx];
                const r_val = right_tuple[self.right_join_col_idx];
                
                if (compare_values(l_val, .lt, r_val)) {
                    self.left_idx += 1;
                } else if (compare_values(l_val, .gt, r_val)) {
                    self.right_idx += 1;
                } else {
                    self.match_right_start_idx = self.right_idx;
                }
            }
        }
        return null;
    }
};

