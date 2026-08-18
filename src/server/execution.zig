const std = @import("std");
const ast = @import("../query/ast.zig");
const exec = @import("../query/executor.zig");
const Catalog = @import("../storage/catalog.zig").Catalog;
const undo = @import("undo.zig");

/// Executes a parsed SQL statement.
pub fn execute_statement(
    allocator: std.mem.Allocator,
    catalog: *Catalog,
    stmt: ast.Statement,
    txn_ctx: ?*@import("../storage/wal/transaction.zig").TransactionContext,
    writer: anytype,
    undo_stack: ?*std.ArrayList(undo.UndoOp),
) !void {
    switch (stmt) {
        .create_table => |c| {
            try catalog.create_table(c.table_name, c.columns);
        },
        .create_index => |c| {
            try catalog.create_index(c.index_name, c.table_name, c.column_name);
        },
        .drop_table => |d| {
            try catalog.drop_table(d.table_name);
        },
        .insert => |i| {
            if (catalog.get_table(i.table_name)) |table| {
                var insert_exec = exec.InsertExecutor{
                    .table = table,
                    .values = i.values,
                    .txn_ctx = txn_ctx,
                    .allocator = allocator,
                };
                try insert_exec.open();
                _ = try insert_exec.next();

                // Record undo for rollback support
                if (undo_stack) |us| {
                    if (i.values.len > 0 and i.values[0] == .int) {
                        const tname = try allocator.dupe(u8, i.table_name);
                        try us.append(allocator, .{ .delete_key = .{ .table_name = tname, .key = i.values[0].int } });
                    }
                }
            } else {
                return error.TableNotFound;
            }
        },
        .delete => |d| {
            if (catalog.get_table(d.table_name)) |table| {
                if (d.condition) |expr| {
                    if (exec.try_extract_index_condition(expr, table)) |extracted| {
                        switch (extracted.cond) {
                            .eq => |eq| {
                                if (undo_stack) |us| {
                                    if (table.search(allocator, txn_ctx, eq.key) catch null) |old_val| {
                                        defer allocator.free(old_val);
                                        const tname = try allocator.dupe(u8, d.table_name);
                                        const v = try allocator.dupe(u8, old_val);
                                        try us.append(allocator, .{ .insert_key = .{ .table_name = tname, .key = eq.key, .value = v } });
                                    }
                                }
                            },
                            else => {},
                        }
                        var delete_exec = exec.DeleteExecutor{
                            .table = table,
                            .condition = extracted.cond,
                            .txn_ctx = txn_ctx,
                            .allocator = allocator,
                        };
                        try delete_exec.open();
                        _ = try delete_exec.next();
                    } else {
                        return error.UnsupportedCondition;
                    }
                } else {
                    return error.MissingCondition;
                }
            } else {
                return error.TableNotFound;
            }
        },
        .update => |u| {
            if (catalog.get_table(u.table_name)) |table| {
                if (u.condition) |expr| {
                    if (exec.try_extract_index_condition(expr, table)) |extracted| {
                        var update_exec = exec.UpdateExecutor{
                            .table = table,
                            .condition = extracted.cond,
                            .index_btree = extracted.index,
                            .column_name = u.column_name,
                            .new_value = u.value,
                            .txn_ctx = txn_ctx,
                            .allocator = allocator,
                        };
                        try update_exec.open();
                        _ = try update_exec.next();
                    } else {
                        return error.UnsupportedCondition;
                    }
                } else {
                    return error.MissingCondition;
                }
            } else {
                return error.TableNotFound;
            }
        },
        .begin, .commit, .rollback => {},
        .select => |s| {
            if (catalog.get_table(s.table_name)) |table| {
                var base_executor: exec.Executor = undefined;
                var seq_exec: exec.SeqScanExecutor = undefined;
                var index_exec: exec.IndexScanExecutor = undefined;
                var filter_exec: exec.FilterExecutor = undefined;

                if (s.condition) |expr| {
                    if (exec.try_extract_index_condition(expr, table)) |extracted| {
                        index_exec = exec.IndexScanExecutor{
                            .table = table,
                            .condition = extracted.cond,
                            .index_btree = extracted.index,
                            .txn_ctx = txn_ctx,
                            .allocator = allocator,
                        };
                        base_executor = .{ .index_scan = &index_exec };
                    } else {
                        seq_exec = exec.SeqScanExecutor{
                            .table = table,
                            .txn_ctx = txn_ctx,
                            .allocator = allocator,
                        };
                        filter_exec = exec.FilterExecutor{
                            .child = .{ .seq_scan = &seq_exec },
                            .expression = expr,
                            .schema = table.schema,
                            .allocator = allocator,
                        };
                        base_executor = .{ .filter = &filter_exec };
                    }
                } else {
                    seq_exec = exec.SeqScanExecutor{
                        .table = table,
                        .txn_ctx = txn_ctx,
                        .allocator = allocator,
                    };
                    base_executor = .{ .seq_scan = &seq_exec };
                }

                var right_seq_exec: exec.SeqScanExecutor = undefined;
                var join_exec: exec.NestedLoopJoinExecutor = undefined;
                var sort_merge_join_exec: exec.SortMergeJoinExecutor = undefined;
                
                var current_schema = table.schema;
                var combined_schema_buf: [128]ast.ColumnDef = undefined;
                
                var left_executor_copy = base_executor;
                var right_executor: exec.Executor = undefined;

                if (s.join_table) |j_table_name| {
                    if (catalog.get_table(j_table_name)) |right_table| {
                        right_seq_exec = exec.SeqScanExecutor{
                            .table = right_table,
                            .txn_ctx = txn_ctx,
                            .allocator = allocator,
                        };
                        right_executor = .{ .seq_scan = &right_seq_exec };
                        
                        const cond = s.join_condition orelse return error.MissingCondition;
                        
                        var use_sort_merge_join = false;
                        if (cond == .column_compare and cond.column_compare.op == .eq) {
                            const cmp = cond.column_compare;
                            var left_col_idx: ?usize = null;
                            var right_col_idx: ?usize = null;
                            
                            if (exec.resolve_column(table.schema, cmp.left_column)) |idx| {
                                left_col_idx = idx;
                                right_col_idx = exec.resolve_column(right_table.schema, cmp.right_column);
                            } else if (exec.resolve_column(table.schema, cmp.right_column)) |idx| {
                                left_col_idx = idx;
                                right_col_idx = exec.resolve_column(right_table.schema, cmp.left_column);
                            }
                            
                            if (left_col_idx != null and right_col_idx != null) {
                                sort_merge_join_exec = exec.SortMergeJoinExecutor{
                                    .left_child = &left_executor_copy,
                                    .right_child = &right_executor,
                                    .left_join_col_idx = left_col_idx.?,
                                    .right_join_col_idx = right_col_idx.?,
                                    .allocator = allocator,
                                };
                                base_executor = .{ .sort_merge_join = &sort_merge_join_exec };
                                use_sort_merge_join = true;
                            }
                        }
                        
                        if (!use_sort_merge_join) {
                            join_exec = exec.NestedLoopJoinExecutor{
                                .left_child = &left_executor_copy,
                                .right_child = &right_executor,
                                .join_condition = cond,
                                .left_schema = table.schema,
                                .right_schema = right_table.schema,
                                .allocator = allocator,
                            };
                            base_executor = .{ .nested_loop_join = &join_exec };
                        }

                        std.debug.assert(table.schema.len + right_table.schema.len <= 128);
                        @memcpy(combined_schema_buf[0..table.schema.len], table.schema);
                        @memcpy(combined_schema_buf[table.schema.len..table.schema.len + right_table.schema.len], right_table.schema);
                        current_schema = combined_schema_buf[0 .. table.schema.len + right_table.schema.len];
                    } else {
                        return error.TableNotFound;
                    }
                }

                var project_exec: exec.ProjectExecutor = undefined;
                var agg_exec: exec.AggregateExecutor = undefined;
                var final_executor: exec.Executor = base_executor;
                var col_indices: ?[]usize = null;
                defer if (col_indices) |idx| allocator.free(idx);

                if (s.aggregates) |aggs| {
                    // Assuming 1 aggregate for now
                    const agg = aggs[0];
                    var group_idx: ?usize = null;
                    var agg_idx: ?usize = null;
                    if (s.group_by) |gb| {
                        group_idx = exec.resolve_column(current_schema, gb) orelse return error.ColumnNotFound;
                    }
                    if (agg.column) |col| {
                        agg_idx = exec.resolve_column(current_schema, col) orelse return error.ColumnNotFound;
                    }

                    agg_exec = exec.AggregateExecutor{
                        .child = base_executor,
                        .group_by_col_idx = group_idx,
                        .agg_op = agg.op,
                        .agg_col_idx = agg_idx,
                        .allocator = allocator,
                    };
                    final_executor = .{ .aggregate = &agg_exec };
                } else if (s.columns) |cols| {
                    col_indices = try allocator.alloc(usize, cols.len);
                    for (cols, 0..) |col_name, i| {
                        col_indices.?[i] = exec.resolve_column(current_schema, col_name) orelse return error.ColumnNotFound;
                    }
                    project_exec = exec.ProjectExecutor{
                        .child = base_executor,
                        .column_indices = col_indices.?,
                        .allocator = allocator,
                    };
                    final_executor = .{ .project = &project_exec };
                }

                var final_executor_copy = final_executor;
                var order_by_exec: exec.OrderByExecutor = undefined;
                if (s.order_by) |ob| {
                    order_by_exec = exec.OrderByExecutor{
                        .child = &final_executor_copy,
                        .order_by_col = ob,
                        .is_desc = s.is_desc,
                        .schema = current_schema,
                        .allocator = allocator,
                    };
                    final_executor = .{ .order_by = &order_by_exec };
                }

                var final_executor_copy2 = final_executor;
                var limit_exec: exec.LimitExecutor = undefined;
                if (s.limit != null or s.offset != null) {
                    limit_exec = exec.LimitExecutor{
                        .child = &final_executor_copy2,
                        .limit = s.limit,
                        .offset = s.offset,
                        .allocator = allocator,
                    };
                    final_executor = .{ .limit = &limit_exec };
                }

                try final_executor.open();
                defer final_executor.close();

                while (try final_executor.next()) |tuple| {
                    defer exec.free_tuple(allocator, tuple);
                    if (@TypeOf(writer) != @TypeOf(null)) {
                        try exec.format_tuple(writer, tuple);
                    }
                }
            } else {
                return error.TableNotFound;
            }
        },
    }
}
