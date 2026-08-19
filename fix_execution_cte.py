import re

with open("src/server/execution.zig", "r") as f:
    content = f.read()

# Add extract_schema
extract_schema_code = """pub fn extract_schema(allocator: std.mem.Allocator, catalog: *Catalog, stmt: ast.Statement) ![]const ast.ColumnDef {
    if (stmt != .select) return error.NotSelect;
    const s = stmt.select;
    
    // Check if it's a temp table first
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

# Handle .with in execute_statement_internal
with_code = """.with => |w| {
            for (w.ctes) |cte| {
                const schema = try extract_schema(allocator, catalog, cte.statement.*);
                try catalog.create_temp_table(cte.name, schema);
                defer allocator.free(schema);
                
                // execute the CTE to populate it
                var temp_exec = exec.InMemoryInsertExecutor{
                    .table = catalog.get_temp_table(cte.name).?,
                    .child = undefined, // We need to build the child... wait.
                    .allocator = allocator,
                };
                
                // Actually, execute_statement_internal is easier!
                // We can pass a special writer or just build an InMemoryInsertExecutor manually.
                // Wait, if we just modify execute_statement_internal to accept a target_temp_table!
            }
        },
        .explain => return,"""

# Actually, rather than doing this manually in python string replace, I will add target_temp_table to execute_statement_internal

