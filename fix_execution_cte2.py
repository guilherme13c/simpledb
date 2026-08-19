import re

with open("src/server/execution.zig", "r") as f:
    content = f.read()

# Add extract_schema
extract_schema_code = """pub fn extract_schema(allocator: std.mem.Allocator, catalog: *Catalog, stmt: ast.Statement) ![]const ast.ColumnDef {
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

pub fn resolve_subqueries"""

content = content.replace("pub fn resolve_subqueries", extract_schema_code)

# Add target_temp_table
content = content.replace(
    "undo_stack: ?*std.ArrayList(undo.UndoOp),\n    out_tuple: ?*[]ast.Value,",
    "undo_stack: ?*std.ArrayList(undo.UndoOp),\n    out_tuple: ?*[]ast.Value,\n    target_temp_table: ?[]const u8,"
)
content = content.replace(
    "return execute_statement_internal(allocator, catalog, parsed_stmt, txn_ctx, writer, undo_stack, null);",
    "return execute_statement_internal(allocator, catalog, parsed_stmt, txn_ctx, writer, undo_stack, null, null);"
)
content = content.replace(
    "try execute_statement_internal(allocator, catalog, c.subquery.*, txn_ctx, null, null, &out_tuple);",
    "try execute_statement_internal(allocator, catalog, c.subquery.*, txn_ctx, null, null, &out_tuple, null);"
)

# Handle .with in execute_statement_internal
with_code = """.explain => return,
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
        },"""
content = content.replace(".explain => return,", with_code)


# Support selecting from temp tables
select_code = """        .select => |s| {
            var base_executor: exec.Executor = undefined;
            var seq_exec: exec.SeqScanExecutor = undefined;
            var mem_exec: exec.InMemoryScanExecutor = undefined;
            var index_exec: exec.IndexScanExecutor = undefined;
            var filter_exec: exec.FilterExecutor = undefined;
            
            var table_schema: []const ast.ColumnDef = undefined;

            if (catalog.get_temp_table(s.table_name)) |temp_table| {
                mem_exec = exec.InMemoryScanExecutor{
                    .table = temp_table,
                    .allocator = allocator,
                };
                base_executor = .{ .in_memory_scan = &mem_exec };
                table_schema = temp_table.schema;
                
                if (s.condition) |expr| {
                    filter_exec = exec.FilterExecutor{
                        .child = &base_executor,
                        .expression = expr,
                        .schema = temp_table.schema,
                        .allocator = allocator,
                    };
                    base_executor = .{ .filter = &filter_exec };
                }
            } else if (catalog.get_table(s.table_name)) |table| {
                table_schema = table.schema;
                if (s.condition) |expr| {
                    if (exec.try_extract_index_condition(expr, table)) |extracted| {
                        const N = table.num_tuples.load(.monotonic);
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
            }"""

old_select_code = """        .select => |s| {
            if (catalog.get_table(s.table_name)) |table| {
                var base_executor: exec.Executor = undefined;
                var seq_exec: exec.SeqScanExecutor = undefined;
                var index_exec: exec.IndexScanExecutor = undefined;
                var filter_exec: exec.FilterExecutor = undefined;

                if (s.condition) |expr| {
                    if (exec.try_extract_index_condition(expr, table)) |extracted| {
                        const N = table.num_tuples.load(.monotonic);
                        // CBO Cost Model
                        // SeqScan requires iterating over all tuples.
                        // IndexScan requires descending the BTree (cost ~3) plus looking up matching heap tuples (cost ~1 for eq).
                        const cost_seq = N;
                        const cost_idx = 4; // Flat cost estimate for point lookup
                        
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
                            // Fallback to SeqScan if table is tiny (SeqScan is better for cache locality on tiny data)
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
                }"""

content = content.replace(old_select_code, select_code)

# Replace table.schema with table_schema in join logic
content = content.replace("var current_schema = table.schema;", "var current_schema = table_schema;")
content = content.replace(".left_schema = table.schema,", ".left_schema = table_schema,")

# Add temp table insertion
capture_code = """                while (try final_executor.next()) |tuple| {
                    defer exec.free_tuple(allocator, tuple);
                    if (target_temp_table) |target_name| {
                        if (catalog.get_temp_table(target_name)) |temp_table| {
                            try temp_table.insert_tuple(tuple);
                        }
                        continue;
                    }
                    if (out_tuple) |out| {"""
content = content.replace("""                while (try final_executor.next()) |tuple| {
                    defer exec.free_tuple(allocator, tuple);
                    if (out_tuple) |out| {""", capture_code)

with open("src/server/execution.zig", "w") as f:
    f.write(content)
