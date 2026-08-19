const std = @import("std");
const ast = @import("../query/ast.zig");
const exec = @import("../query/executor.zig");
const Catalog = @import("../storage/catalog.zig").Catalog;
const undo = @import("undo.zig");
const transaction = @import("../storage/wal/transaction.zig");

/// Executes a parsed SQL statement.
pub fn extract_schema(allocator: std.mem.Allocator, catalog: *Catalog, stmt: ast.Statement) ![]const ast.ColumnDef {
    if (stmt != .select) return error.NotSelect;
    const s = stmt.select;
    
    if (catalog.get_temp_table(s.table_name)) |table| {
        return table.schema;
    }
    if (catalog.get_table(s.table_name)) |table| {
        if (s.columns) |cols| {
            var schema = try allocator.alloc(ast.ColumnDef, cols.len);
            for (cols, 0..) |col_name, i| {
                for (table.schema) |table_col| {
                    if (std.mem.eql(u8, col_name, table_col.name)) {
                        schema[i] = table_col;
                        break;
                    }
                }
            }
            return schema;
        } else {
            var schema = try allocator.alloc(ast.ColumnDef, table.schema.len);
            for (table.schema, 0..) |table_col, i| {
                schema[i] = table_col;
            }
            return schema;
        }
    }
    return error.TableNotFound;
}

pub fn resolve_subqueries(
    allocator: std.mem.Allocator,
    catalog: *Catalog,
    txn_ctx: ?*transaction.TransactionContext,
    expr: *ast.Expression,
) anyerror!void {
    switch (expr.*) {
        .compare => {},
        .column_compare => {},
        .and_expr => |*a| {
            const left = @constCast(a.left);
            const right = @constCast(a.right);
            try resolve_subqueries(allocator, catalog, txn_ctx, left);
            try resolve_subqueries(allocator, catalog, txn_ctx, right);
        },
        .compare_subquery => |c| {
            var out_tuple: []ast.Value = undefined;
            try execute_statement_internal(allocator, catalog, c.subquery.*, txn_ctx, null, null, &out_tuple, null);
            defer exec.free_tuple(allocator, out_tuple);
            
            if (out_tuple.len == 0) return error.SubqueryEmpty;
            
            expr.* = .{
                .compare = .{
                    .column = c.column,
                    .op = c.op,
                    .value = try exec.dupe_value(allocator, out_tuple[0]),
                }
            };
        }
    }
}

pub fn execute_statement(
    allocator: std.mem.Allocator,
    catalog: *Catalog,
    parsed_stmt: ast.Statement,
    txn_ctx: ?*transaction.TransactionContext,
    writer: anytype,
    undo_stack: ?*std.ArrayList(undo.UndoOp),
) !void {
    return execute_statement_internal(allocator, catalog, parsed_stmt, txn_ctx, writer, undo_stack, null, null);
}

fn execute_statement_internal(
    allocator: std.mem.Allocator,
    catalog: *Catalog,
    parsed_stmt: ast.Statement,
    txn_ctx: ?*transaction.TransactionContext,
    writer: anytype,
    undo_stack: ?*std.ArrayList(undo.UndoOp),
    out_tuple: ?*[]ast.Value,
    target_temp_table: ?[]const u8,
) !void {
    var stmt = parsed_stmt;
    var is_explain = false;
    
    if (stmt == .explain) {
        is_explain = true;
        stmt = stmt.explain.*;
    }

    if (stmt == .select and stmt.select.condition != null) {
        var cond = stmt.select.condition.?;
        try resolve_subqueries(allocator, catalog, txn_ctx, &cond);
        stmt.select.condition = cond;
    }

    switch (stmt) {
        .explain => return,
        .with => |w| {
            for (w.ctes) |cte| {
                const schema = try extract_schema(allocator, catalog, cte.statement.*);
                try catalog.create_temp_table(cte.name, schema);
                allocator.free(schema);
                try execute_statement_internal(allocator, catalog, cte.statement.*, txn_ctx, null, null, null, cte.name);
            }
            try execute_statement_internal(allocator, catalog, w.statement.*, txn_ctx, writer, undo_stack, out_tuple, target_temp_table);
            for (w.ctes) |cte| {
                try catalog.drop_temp_table(cte.name);
            }
        },
        .create_table => |c| {
            try catalog.create_table(c.table_name, c.columns);
        },
        .alter_table => |a| {
            try catalog.alter_table(a.table_name, a.action);
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
                var base_executor: exec.Executor = undefined;
                var seq_exec: exec.SeqScanExecutor = undefined;
                var index_exec: exec.IndexScanExecutor = undefined;
                var filter_exec: exec.FilterExecutor = undefined;

                if (d.condition) |expr| {
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

                var delete_exec = exec.DeleteExecutor{
                    .table = table,
                    .child = &base_executor,
                    .txn_ctx = txn_ctx,
                    .allocator = allocator,
                };
                try delete_exec.open();
                defer delete_exec.close();
                _ = try delete_exec.next();
            } else {
                return error.TableNotFound;
            }
        },
        .update => |u| {
            if (catalog.get_table(u.table_name)) |table| {
                var base_executor: exec.Executor = undefined;
                var seq_exec: exec.SeqScanExecutor = undefined;
                var index_exec: exec.IndexScanExecutor = undefined;
                var filter_exec: exec.FilterExecutor = undefined;

                if (u.condition) |expr| {
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

                var update_exec = exec.UpdateExecutor{
                    .table = table,
                    .child = &base_executor,
                    .column_name = u.column_name,
                    .new_value = u.value,
                    .txn_ctx = txn_ctx,
                    .allocator = allocator,
                };
                try update_exec.open();
                defer update_exec.close();
                _ = try update_exec.next();
            } else {
                return error.TableNotFound;
            }
        },
        .begin, .commit, .rollback => {},
        .select => |s| {
            var base_executor: exec.Executor = undefined;
            var seq_exec: exec.SeqScanExecutor = undefined;
            var mem_exec: exec.InMemoryScanExecutor = undefined;
            var index_exec: exec.IndexScanExecutor = undefined;
            var filter_exec: exec.FilterExecutor = undefined;
            
            var table_schema: []const ast.ColumnDef = undefined;
            var num_left_tuples: u64 = 0;

            if (catalog.get_temp_table(s.table_name)) |temp_table| {
                mem_exec = exec.InMemoryScanExecutor{
                    .table = temp_table,
                    .allocator = allocator,
                };
                base_executor = .{ .in_memory_scan = &mem_exec };
                table_schema = temp_table.schema;
                num_left_tuples = temp_table.tuples.items.len;
                
                if (s.condition) |expr| {
                    filter_exec = exec.FilterExecutor{
                        .child = base_executor,
                        .expression = expr,
                        .schema = temp_table.schema,
                        .allocator = allocator,
                    };
                    base_executor = .{ .filter = &filter_exec };
                }
            } else if (catalog.get_table(s.table_name)) |table| {
                table_schema = table.schema;
                num_left_tuples = num_left_tuples;
                
                if (s.condition) |expr| {
                    if (exec.try_extract_index_condition(expr, table)) |extracted| {
                        const N = num_left_tuples;
                        // CBO Cost Model
                        const cost_seq = N;
                        const cost_idx = 4;
                        
                        if (cost_idx <= cost_seq) {
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
            } else {
                return error.TableNotFound;
            }
var right_seq_exec: exec.SeqScanExecutor = undefined;
                var join_exec: exec.NestedLoopJoinExecutor = undefined;
                var sort_merge_join_exec: exec.SortMergeJoinExecutor = undefined;
                var hash_join_exec: exec.HashJoinExecutor = undefined;
                
                var current_schema = table_schema;
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
                        
                        var use_optimized_join = false;
                        if (cond == .column_compare and cond.column_compare.op == .eq) {
                            const cmp = cond.column_compare;
                            var left_col_idx: ?usize = null;
                            var right_col_idx: ?usize = null;
                            
                            if (exec.resolve_column(table_schema, cmp.left_column)) |idx| {
                                left_col_idx = idx;
                                right_col_idx = exec.resolve_column(right_table.schema, cmp.right_column);
                            } else if (exec.resolve_column(table_schema, cmp.right_column)) |idx| {
                                left_col_idx = idx;
                                right_col_idx = exec.resolve_column(right_table.schema, cmp.left_column);
                            }
                            
                            if (left_col_idx != null and right_col_idx != null) {
                                const N_left = num_left_tuples;
                                const N_right = right_table.num_tuples.load(.monotonic);

                                // CBO Cost Model
                                // NestedLoopJoin cost = N_left * N_right
                                const cost_nlj = N_left * N_right;
                                
                                // SortMergeJoin cost = N_left * log2(N_left) + N_right * log2(N_right) + N_left + N_right
                                const n_left_log = if (N_left > 1) N_left * std.math.log2_int(u64, N_left) else 0;
                                const n_right_log = if (N_right > 1) N_right * std.math.log2_int(u64, N_right) else 0;
                                const cost_smj = n_left_log + n_right_log + N_left + N_right;

                                // HashJoin cost = N_left + N_right (hash build and probe)
                                // We add a constant overhead factor to represent hashing costs
                                const cost_hj = (N_left + N_right) * 2;

                                // Pick the cheapest join strategy
                                if (s.join_type == .inner) {
                                    if (cost_hj <= cost_smj and cost_hj <= cost_nlj) {
                                        hash_join_exec = exec.HashJoinExecutor{
                                            .left_child = &left_executor_copy,
                                            .right_child = &right_executor,
                                            .left_join_col_idx = left_col_idx.?,
                                            .right_join_col_idx = right_col_idx.?,
                                            .allocator = allocator,
                                        };
                                        base_executor = .{ .hash_join = &hash_join_exec };
                                        use_optimized_join = true;
                                    } else if (cost_smj <= cost_nlj) {
                                        sort_merge_join_exec = exec.SortMergeJoinExecutor{
                                            .left_child = &left_executor_copy,
                                            .right_child = &right_executor,
                                            .left_join_col_idx = left_col_idx.?,
                                            .right_join_col_idx = right_col_idx.?,
                                            .allocator = allocator,
                                        };
                                        base_executor = .{ .sort_merge_join = &sort_merge_join_exec };
                                        use_optimized_join = true;
                                    }
                                }
                        }
                        
                            }
                        if (!use_optimized_join) {
                            join_exec = exec.NestedLoopJoinExecutor{
                                .left_child = &left_executor_copy,
                                .right_child = &right_executor,
                                .join_condition = cond,
                                .join_type = s.join_type,
                                .left_schema = table_schema,
                                .right_schema = right_table.schema,
                                .allocator = allocator,
                            };
                            base_executor = .{ .nested_loop_join = &join_exec };
                        }

                        std.debug.assert(table_schema.len + right_table.schema.len <= 128);
                        @memcpy(combined_schema_buf[0..table_schema.len], table_schema);
                        @memcpy(combined_schema_buf[table_schema.len..table_schema.len + right_table.schema.len], right_table.schema);
                        current_schema = combined_schema_buf[0 .. table_schema.len + right_table.schema.len];
                    } else {
                        return error.TableNotFound;
                    }
                }


                var win_exec: exec.WindowExecutor = undefined;
                var win_base_exec_copy = base_executor;
                if (s.window_functions) |wfs| {
                    win_exec = exec.WindowExecutor{
                        .child = &win_base_exec_copy,
                        .window_functions = wfs,
                        .input_schema = current_schema,
                        .allocator = allocator,
                    };
                    base_executor = .{ .window = &win_exec };
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
                    const num_win_funcs = if (s.window_functions) |wfs| wfs.len else 0;
                    col_indices = try allocator.alloc(usize, cols.len + num_win_funcs);
                    for (cols, 0..) |col_name, i| {
                        col_indices.?[i] = exec.resolve_column(current_schema, col_name) orelse return error.ColumnNotFound;
                    }
                    for (0..num_win_funcs) |i| {
                        col_indices.?[cols.len + i] = current_schema.len + i;
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
                
                if (is_explain) {
                    if (@TypeOf(writer) != @TypeOf(null)) {
                        try final_executor.explain(writer, 0);
                    }
                    return;
                }

                try final_executor.open();
                defer final_executor.close();

                while (try final_executor.next()) |tuple| {
                    defer exec.free_tuple(allocator, tuple);
                    if (target_temp_table) |target_name| {
                        if (catalog.get_temp_table(target_name)) |temp_table| {
                            try temp_table.insert_tuple(tuple);
                        }
                        continue;
                    }
                    if (out_tuple) |out| {
                        out.* = try allocator.alloc(ast.Value, tuple.len);
                        for (tuple, 0..) |v, i| out.*[i] = try exec.dupe_value(allocator, v);
                        break;
                    }
                    if (@TypeOf(writer) != @TypeOf(null)) {
                        try exec.format_tuple(writer, tuple);
                    }
                }
        },
    }
}
