const std = @import("std");
const ast = @import("ast.zig");
const Table = @import("../storage/table.zig").Table;
const Catalog = @import("../storage/catalog.zig").Catalog;
const TransactionContext = @import("../storage/wal/transaction.zig").TransactionContext;

/// Free a tuple of Values allocated by an executor. Frees owned varchar strings.

pub fn dupe_value(allocator: std.mem.Allocator, val: ast.Value) !ast.Value {
    return switch (val) {
        .int => |v| .{ .int = v },
        .null_val => .{ .null_val = {} },
        .bool => |v| .{ .bool = v },
        .varchar => |v| .{ .varchar = try allocator.dupe(u8, v) },
        .float => |v| .{ .float = v },
        .timestamp => |v| .{ .timestamp = v },
        .json => |v| .{ .json = try allocator.dupe(u8, v) },
        .uuid => |v| .{ .uuid = v },
        .signed_int => |v| .{ .signed_int = v },
    };
}
pub fn free_tuple(allocator: std.mem.Allocator, tuple: []ast.Value) void {
    for (tuple) |v| {
        if (v == .varchar) allocator.free(v.varchar);
        if (v == .json) allocator.free(v.json);
    }
    allocator.free(tuple);
}

/// Format a tuple of Values into a writer as pipe-separated text.
pub fn format_tuple(writer: anytype, tuple: []const ast.Value) !void {
    for (tuple, 0..) |v, idx| {
        if (idx > 0) try writer.writeAll(" | ");
        switch (v) {
            .int => |val| try writer.print("{d}", .{val}),
            .null_val => try writer.print("NULL", .{}),
            .bool => |val| try writer.print("{}", .{val}),
            .varchar => |val| try writer.print("{s}", .{val}),
            .float => |val| try writer.print("{d}", .{val}),
            .timestamp => |val| try writer.print("{d}", .{val}),
            .json => |val| try writer.print("{s}", .{val}),
            .uuid => |val| try writer.print("{s}", .{std.fmt.bytesToHex(val, .lower)}),
            .signed_int => |val| try writer.print("{d}", .{val}),
        }
    }
    try writer.writeAll("\n");
}

pub const ExecError = error{
    OutOfMemory,
    SchemaMismatch,
    InvalidValuesForLegacyTable,
    MissingPrimaryKey,
    PageFault,
    FrameNotFound,
    OutOfSpace,
    BTreeError,
    Unexpected,
    SlotError,
    DuplicateKey,
    LogError,
};

/// Executor represents a node in the query execution plan.
pub const Executor = union(enum) {
    seq_scan: *SeqScanExecutor,
    filter: *FilterExecutor,
    project: *ProjectExecutor,
    nested_loop_join: *NestedLoopJoinExecutor,
    hash_join: *HashJoinExecutor,
    sort_merge_join: *SortMergeJoinExecutor,
    aggregate: *AggregateExecutor,
    insert: *InsertExecutor,
    index_scan: *IndexScanExecutor,
    delete: *DeleteExecutor,
    update: *UpdateExecutor,
    order_by: *OrderByExecutor,
    limit: *LimitExecutor,
    in_memory_scan: *InMemoryScanExecutor,
    in_memory_insert: *InMemoryInsertExecutor,
    window: *WindowExecutor,

    /// Initializes the execution plan.
    pub fn open(self: *Executor) anyerror!void {
        switch (self.*) {
            .seq_scan => |e| try e.open(),
            .filter => |e| try e.open(),
            .project => |e| try e.open(),
            .nested_loop_join => |e| try e.open(),
            .hash_join => |e| try e.open(),
            .sort_merge_join => |e| try e.open(),
            .aggregate => |e| try e.open(),
            .insert => |e| try e.open(),
            .index_scan => |e| try e.open(),
            .delete => |e| try e.open(),
            .update => |e| try e.open(),
            .order_by => |e| try e.open(),
            .limit => |e| try e.open(),
            .in_memory_scan => |e| try e.open(),
            .window => |e| try e.open(),
            .in_memory_insert => |e| try e.open(),
        }
    }

    /// Retrieves the next tuple from the execution plan.
    pub fn next(self: *Executor) anyerror!?[]ast.Value {
        switch (self.*) {
            .seq_scan => |e| return try e.next(),
            .filter => |e| return try e.next(),
            .project => |e| return try e.next(),
            .nested_loop_join => |e| return try e.next(),
            .hash_join => |e| return try e.next(),
            .sort_merge_join => |e| return try e.next(),
            .aggregate => |e| return try e.next(),
            .insert => |e| return try e.next(),
            .index_scan => |e| return try e.next(),
            .delete => |e| return try e.next(),
            .update => |e| return try e.next(),
            .order_by => |e| return try e.next(),
            .limit => |e| return try e.next(),
            .in_memory_scan => |e| return try e.next(),
            .window => |e| return try e.next(),
            .in_memory_insert => |e| return try e.next(),
        }
    }
    /// Closes the execution plan and frees associated resources.
    pub fn close(self: *Executor) void {
        switch (self.*) {
            .seq_scan => |e| e.close(),
            .filter => |e| e.close(),
            .project => |e| e.close(),
            .nested_loop_join => |e| e.close(),
            .hash_join => |e| e.close(),
            .sort_merge_join => |e| e.close(),
            .aggregate => |e| e.close(),
            .insert => {},
            .index_scan => |e| e.close(),
            .delete => {},
            .update => |e| e.close(),
            .order_by => |e| e.close(),
            .limit => |e| e.close(),
            .in_memory_scan => |e| e.close(),
            .window => |e| e.close(),
            .in_memory_insert => |e| e.close(),
        }
    }

    /// Prints the query plan tree.
    pub fn explain(self: *Executor, writer: anytype, depth: usize) anyerror!void {
        var indent_buf: [64]u8 = undefined;
        @memset(&indent_buf, ' ');
        const indent_len = @min(depth * 2, 64);
        const indent = indent_buf[0..indent_len];
        
        switch (self.*) {
            .seq_scan => try writer.print("{s}-> SeqScan\n", .{indent}),
            .index_scan => try writer.print("{s}-> IndexScan\n", .{indent}),
            .filter => |e| {
                try writer.print("{s}-> Filter\n", .{indent});
                try e.child.explain(writer, depth + 1);
            },
            .project => |e| {
                try writer.print("{s}-> Project\n", .{indent});
                try e.child.explain(writer, depth + 1);
            },
            .nested_loop_join => |e| {
                try writer.print("{s}-> NestedLoopJoin\n", .{indent});
                try e.left_child.explain(writer, depth + 1);
                try e.right_child.explain(writer, depth + 1);
            },
            .sort_merge_join => |e| {
                try writer.print("{s}-> SortMergeJoin\n", .{indent});
                try e.left_child.explain(writer, depth + 1);
                try e.right_child.explain(writer, depth + 1);
            },
            .aggregate => |e| {
                try writer.print("{s}-> Aggregate\n", .{indent});
                try e.child.explain(writer, depth + 1);
            },
            .insert => try writer.print("{s}-> Insert\n", .{indent}),
            .delete => {
                try writer.print("{s}-> Delete\n", .{indent});
                // Note: Delete may not have child explicitly in some designs, but if it does:
                // try e.child.explain(writer, depth + 1);
            },
            .update => {
                try writer.print("{s}-> Update\n", .{indent});
                // try e.child.explain(writer, depth + 1);
            },
            .order_by => |e| {
                try writer.print("{s}-> OrderBy\n", .{indent});
                try e.child.explain(writer, depth + 1);
            },
            .limit => |e| {
                try writer.print("{s}-> Limit\n", .{indent});
                try e.child.explain(writer, depth + 1);
            },
            .in_memory_scan => try writer.print("{s}-> InMemoryScan\n", .{indent}),
            .in_memory_insert => |e| {
                try writer.print("{s}-> InMemoryInsert\n", .{indent});
                try e.child.explain(writer, depth + 1);
            },
            .window => |e| try e.explain(writer, depth),
            .hash_join => |e| {
                try writer.print("{s}-> HashJoin\n", .{indent});
                try e.left_child.explain(writer, depth + 1);
                try e.right_child.explain(writer, depth + 1);
            },
        }
    }
};


pub const SeqScanExecutor = @import("executor/seq_scan.zig").SeqScanExecutor;
pub const FilterExecutor = @import("executor/filter.zig").FilterExecutor;
pub const NestedLoopJoinExecutor = @import("executor/nested_loop_join.zig").NestedLoopJoinExecutor;
pub const HashJoinExecutor = @import("executor/hash_join.zig").HashJoinExecutor;
pub const SortMergeJoinExecutor = @import("executor/sort_merge_join.zig").SortMergeJoinExecutor;
pub const ProjectExecutor = @import("executor/project.zig").ProjectExecutor;
pub const AggregateExecutor = @import("executor/aggregate.zig").AggregateExecutor;
pub const WindowExecutor = @import("executor/window.zig").WindowExecutor;
pub const IndexScanExecutor = @import("executor/index_scan.zig").IndexScanExecutor;
pub const InsertExecutor = @import("executor/insert.zig").InsertExecutor;
pub const DeleteExecutor = @import("executor/delete.zig").DeleteExecutor;
pub const UpdateExecutor = @import("executor/update.zig").UpdateExecutor;
pub const OrderByExecutor = @import("executor/order_by.zig").OrderByExecutor;
pub const LimitExecutor = @import("executor/limit.zig").LimitExecutor;
pub const InMemoryScanExecutor = @import("executor/in_memory_scan.zig").InMemoryScanExecutor;
pub const InMemoryInsertExecutor = @import("executor/in_memory_insert.zig").InMemoryInsertExecutor;

pub const ValueContext = struct {
    pub fn hash(self: @This(), key: ast.Value) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .int => |v| hasher.update(std.mem.asBytes(&v)),
            .null_val => return 0,
            .bool => |v| hasher.update(std.mem.asBytes(&v)),
            .varchar => |v| hasher.update(v),
            .float => |v| hasher.update(std.mem.asBytes(&v)),
            .timestamp => |v| hasher.update(std.mem.asBytes(&v)),
            .json => |v| hasher.update(v),
            .uuid => |v| hasher.update(&v),
            .signed_int => |v| hasher.update(std.mem.asBytes(&v)),
        }
        return hasher.final();
    }

    pub fn eql(self: @This(), a: ast.Value, b: ast.Value) bool {
        _ = self;
        return compare_values(a, .eq, b);
    }
};

// ─── SeqScan ─────────────────────────────────────────────────────────────────

/// Resolve a column name to its index in the schema.
pub fn resolve_column(schema: []const ast.ColumnDef, name: []const u8) ?usize {
    for (schema, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, name)) return i;
    }
    return null;
}

/// Compare two Values using a CompareOp. Returns true if the comparison holds.
pub fn compare_values(lhs: ast.Value, op: ast.CompareOp, rhs: ast.Value) bool {
    // Type must match
    if (@as(ast.ValueType, lhs) != @as(ast.ValueType, rhs)) return false;

    switch (lhs) {
        .null_val => return false,
        .int => |a| {
            const b = rhs.int;
            return switch (op) {
                .eq => a == b,
                .neq => a != b,
                .gt => a > b,
                .gte => a >= b,
                .lt => a < b,
                .lte => a <= b,
            };
        },
        .signed_int => |a| {
            const b = rhs.signed_int;
            return switch (op) {
                .eq => a == b,
                .neq => a != b,
                .gt => a > b,
                .gte => a >= b,
                .lt => a < b,
                .lte => a <= b,
            };
        },
        .float => |a| {
            const b = rhs.float;
            return switch (op) {
                .eq => a == b,
                .neq => a != b,
                .gt => a > b,
                .gte => a >= b,
                .lt => a < b,
                .lte => a <= b,
            };
        },
        .timestamp => |a| {
            const b = rhs.timestamp;
            return switch (op) {
                .eq => a == b,
                .neq => a != b,
                .gt => a > b,
                .gte => a >= b,
                .lt => a < b,
                .lte => a <= b,
            };
        },
        .uuid => |a| {
            const b = rhs.uuid;
            const ord = std.mem.order(u8, &a, &b);
            return switch (op) {
                .eq => ord == .eq,
                .neq => ord != .eq,
                .gt => ord == .gt,
                .gte => ord == .gt or ord == .eq,
                .lt => ord == .lt,
                .lte => ord == .lt or ord == .eq,
            };
        },
        .json => |a| {
            const b = rhs.json;
            return switch (op) {
                .eq => std.mem.eql(u8, a, b),
                .neq => !std.mem.eql(u8, a, b),
                else => false,
            };
        },
        .bool => |a| {
            const b = rhs.bool;
            return switch (op) {
                .eq => a == b,
                .neq => a != b,
                else => false, // gt/lt/gte/lte don't make sense for bool
            };
        },
        .varchar => |a| {
            const b = rhs.varchar;
            const ord = std.mem.order(u8, a, b);
            return switch (op) {
                .eq => ord == .eq,
                .neq => ord != .eq,
                .gt => ord == .gt,
                .gte => ord == .gt or ord == .eq,
                .lt => ord == .lt,
                .lte => ord == .lt or ord == .eq,
            };
        },
    }
}

/// Evaluate an Expression against a tuple using the schema for column resolution.
pub fn evaluate_expression(expr: ast.Expression, tuple: []const ast.Value, schema: []const ast.ColumnDef) bool {
    switch (expr) {
        .compare_subquery => unreachable,
        .compare => |cmp| {
            const col_idx = resolve_column(schema, cmp.column) orelse return false;
            if (col_idx >= tuple.len) return false;
            return compare_values(tuple[col_idx], cmp.op, cmp.value);
        },
        .column_compare => return false,
        .and_expr => |a| {
            return evaluate_expression(a.left.*, tuple, schema) and
                evaluate_expression(a.right.*, tuple, schema);
        },
    }
}

pub fn evaluate_join_expression(
    expr: ast.Expression,
    left_tuple: []const ast.Value,
    left_schema: []const ast.ColumnDef,
    right_tuple: []const ast.Value,
    right_schema: []const ast.ColumnDef,
) ExecError!bool {
    switch (expr) {
        .compare_subquery => unreachable,
        .compare => |cmp| {
            if (resolve_column(left_schema, cmp.column)) |idx| {
                return compare_values(left_tuple[idx], cmp.op, cmp.value);
            } else if (resolve_column(right_schema, cmp.column)) |idx| {
                return compare_values(right_tuple[idx], cmp.op, cmp.value);
            }
            return error.SchemaMismatch;
        },
        .column_compare => |cmp| {
            var val1: ast.Value = undefined;
            if (resolve_column(left_schema, cmp.left_column)) |idx| {
                val1 = left_tuple[idx];
            } else if (resolve_column(right_schema, cmp.left_column)) |idx| {
                val1 = right_tuple[idx];
            } else {
                return error.SchemaMismatch;
            }

            var val2: ast.Value = undefined;
            if (resolve_column(right_schema, cmp.right_column)) |idx| {
                val2 = right_tuple[idx];
            } else if (resolve_column(left_schema, cmp.right_column)) |idx| {
                val2 = left_tuple[idx];
            } else {
                return error.SchemaMismatch;
            }

            return compare_values(val1, cmp.op, val2);
        },
        .and_expr => |a| {
            return (try evaluate_join_expression(a.left.*, left_tuple, left_schema, right_tuple, right_schema)) and
                   (try evaluate_join_expression(a.right.*, left_tuple, left_schema, right_tuple, right_schema));
        },
    }
}

/// Try to convert a simple primary-key expression (first column = int) into an IndexScan Condition.
pub fn try_extract_index_condition(expr: ast.Expression, table: *@import("../storage/table.zig").Table) ?struct { cond: ast.Condition, index: ?*@import("../storage/index/btree.zig").BTree } {
    if (table.schema.len == 0) return null;

    switch (expr) {
        .compare_subquery => unreachable,
        .compare => |cmp| {
            if (cmp.op != .eq) return null;

            if (std.mem.eql(u8, cmp.column, table.schema[0].name) and cmp.value == .int) {
                return .{ .cond = .{ .eq = .{ .key = cmp.value.int } }, .index = null };
            }

            var it = table.indexes.iterator();
            while (it.next()) |kv| {
                const idx_name = kv.key_ptr.*;
                _ = idx_name;
                const index_def = kv.value_ptr.*;
                if (std.mem.eql(u8, cmp.column, table.schema[index_def.column_idx].name)) {
                    const hash_key = switch (cmp.value) {
                        .int => |v| v,
                        .varchar => |s| std.hash.Wyhash.hash(0, s),
                        .bool => |b| @as(u64, if (b) 1 else 0),
                        .float => |f| @as(u64, @bitCast(f)),
                        .signed_int => |i| @as(u64, @bitCast(i)),
                        else => return null,
                    };
                    return .{ .cond = .{ .eq = .{ .key = hash_key } }, .index = index_def.btree };
                }
            }
            return null;
        },
        .and_expr => |a| {
            // Check for range pattern: col >= X AND col <= Y
            if (a.left.* == .compare and a.right.* == .compare) {
                const l = a.left.compare;
                const r = a.right.compare;

                if (!std.mem.eql(u8, l.column, table.schema[0].name)) return null;
                if (!std.mem.eql(u8, r.column, table.schema[0].name)) return null;
                if (l.value != .int or r.value != .int) return null;

                if (l.op == .gte and r.op == .lte) {
                    return .{ .cond = .{ .range = .{ .start = l.value.int, .end = r.value.int } }, .index = null };
                }
                if (l.op == .lte and r.op == .gte) {
                    return .{ .cond = .{ .range = .{ .start = r.value.int, .end = l.value.int } }, .index = null };
                }
            }
            return null;
        },
        .column_compare => return null,
    }
}
