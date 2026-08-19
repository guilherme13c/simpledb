import re

with open("src/server/execution.zig", "r") as f:
    code = f.read()

# 1. Add resolve_subqueries and extract_schema
helpers = """pub fn extract_schema(allocator: std.mem.Allocator, catalog: *Catalog, stmt: ast.Statement) ![]const ast.ColumnDef {
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

pub fn execute_statement"""

code = code.replace("pub fn execute_statement", helpers)

# 2. Refactor execute_statement to execute_statement_internal
execute_sig = """pub fn execute_statement(
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
) !void {"""

code = re.sub(r'pub fn execute_statement\([^)]+\) !void \{', execute_sig, code)

# 3. Add .with handling and .select condition subqueries
stmt_logic = """    var is_explain = false;
    
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
        },"""

code = re.sub(r'    var is_explain = false;\s+if \(stmt == \.explain\) \{\s+is_explain = true;\s+stmt = stmt\.explain\.\*;\s+\}\s+switch \(stmt\) \{\s+\.explain => return,', stmt_logic, code)

# 4. Handle temp tables in .select
select_start = """        .select => |s| {
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
                table_schema = table.schema;"""

code = re.sub(r'        \.select => \|s\| \{\s+if \(catalog\.get_table\(s\.table_name\)\) \|table\| \{\s+var base_executor: exec\.Executor = undefined;\s+var seq_exec: exec\.SeqScanExecutor = undefined;\s+var index_exec: exec\.IndexScanExecutor = undefined;\s+var filter_exec: exec\.FilterExecutor = undefined;', select_start, code)

# Fix references to table.schema in .select
code = code.replace("var current_schema = table.schema;", "var current_schema = table_schema;")
code = code.replace(".left_schema = table.schema,", ".left_schema = table_schema,")
code = code.replace("table.schema.len", "table_schema.len")
code = code.replace("table.schema)", "table_schema)")

# 5. Handle Join types
join_opt_start = """                                // Pick the cheapest join strategy
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
                                }"""
code = re.sub(r'                                // Pick the cheapest join strategy.*?use_optimized_join = true;\s+\}\s+\}', join_opt_start, code, flags=re.DOTALL)

code = code.replace(
""".right_child = &right_executor,
                                .join_condition = cond,
                                .left_schema = table_schema,""",
""".right_child = &right_executor,
                                .join_condition = cond,
                                .join_type = s.join_type,
                                .left_schema = table_schema,""")

# 6. Capture outputs
capture_logic = """                while (try final_executor.next()) |tuple| {
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
                }"""

code = re.sub(r'                while \(try final_executor\.next\(\)\) \|tuple\| \{\s+defer exec\.free_tuple\(allocator, tuple\);\s+if \(@TypeOf\(writer\) != @TypeOf\(null\)\) \{\s+try exec\.format_tuple\(writer, tuple\);\s+\}\s+\}', capture_logic, code)

with open("src/server/execution.zig", "w") as f:
    f.write(code)
