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

// ─── HashJoin ─────────────────────────────────────────────────────────────────

const ValueContext = @import("../executor.zig").ValueContext;

/// HashJoinExecutor implements the execution logic for the HashJoinExecutor operator.
pub const HashJoinExecutor = struct {
    left_child: *Executor,
    right_child: *Executor,
    left_join_col_idx: usize,
    right_join_col_idx: usize,
    allocator: std.mem.Allocator,

    hash_table: std.HashMap(ast.Value, std.ArrayList([]ast.Value), ValueContext, std.hash_map.default_max_load_percentage) = undefined,
    current_right_tuple: ?[]ast.Value = null,
    current_left_matches: ?[]const []ast.Value = null,
    match_idx: usize = 0,
    initialized: bool = false,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *HashJoinExecutor) !void {
        try self.left_child.open();
        try self.right_child.open();

        self.hash_table = std.HashMap(ast.Value, std.ArrayList([]ast.Value), ValueContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        
        while (try self.left_child.next()) |tuple| {
            var duped = try self.allocator.alloc(ast.Value, tuple.len);
            for (tuple, 0..) |v, i| {
                duped[i] = try dupe_value(self.allocator, v);
            }
            const key_val = duped[self.left_join_col_idx];
            var key_to_insert = key_val;
            if (key_to_insert == .varchar or key_to_insert == .json) {
                 if (key_to_insert == .varchar) key_to_insert = .{ .varchar = try self.allocator.dupe(u8, key_val.varchar) } else key_to_insert = .{ .json = try self.allocator.dupe(u8, key_val.json) };
            }
            
            var res = try self.hash_table.getOrPut(key_to_insert);
            if (!res.found_existing) {
                res.value_ptr.* = std.ArrayList([]ast.Value).empty;
            } else {
                if (key_to_insert == .varchar) self.allocator.free(key_to_insert.varchar) else if (key_to_insert == .json) self.allocator.free(key_to_insert.json);
            }
            try res.value_ptr.append(self.allocator, duped);
            free_tuple(self.allocator, tuple);
        }
        
        self.current_right_tuple = try self.right_child.next();
        self.match_idx = 0;
        self.current_left_matches = null;
        self.initialized = true;
    }

    /// Cleans up any resources or state allocated by the executor.
    pub fn close(self: *HashJoinExecutor) void {
        if (!self.initialized) return;
        self.left_child.close();
        self.right_child.close();

        var it = self.hash_table.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .varchar) {
                self.allocator.free(entry.key_ptr.varchar);
            }
            for (entry.value_ptr.items) |tuple| {
                free_tuple(self.allocator, tuple);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.hash_table.deinit();

        if (self.current_right_tuple) |t| free_tuple(self.allocator, t);
        self.initialized = false;
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *HashJoinExecutor) !?[]ast.Value {
        while (self.current_right_tuple != null) {
            const right_tuple = self.current_right_tuple.?;

            if (self.current_left_matches == null) {
                if (self.right_join_col_idx < right_tuple.len) {
                    const key = right_tuple[self.right_join_col_idx];
                    if (self.hash_table.get(key)) |matches| {
                        self.current_left_matches = matches.items;
                        self.match_idx = 0;
                    }
                }
            }

            if (self.current_left_matches) |matches| {
                if (self.match_idx < matches.len) {
                    const left_tuple = matches[self.match_idx];
                    self.match_idx += 1;

                    var joined = try self.allocator.alloc(ast.Value, left_tuple.len + right_tuple.len);
                    for (left_tuple, 0..) |v, i| {
                        joined[i] = try dupe_value(self.allocator, v);
                    }
                    for (right_tuple, 0..) |v, i| {
                        joined[left_tuple.len + i] = try dupe_value(self.allocator, v);
                    }
                    return joined;
                } else {
                    self.current_left_matches = null;
                }
            }

            if (self.current_left_matches == null) {
                free_tuple(self.allocator, right_tuple);
                self.current_right_tuple = try self.right_child.next();
            }
        }
        return null;
    }
};

