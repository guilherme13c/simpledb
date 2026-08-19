with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace(".int => @as(u64, @bitCast(@as(i64, key.int))),", ".int => @as(u64, @bitCast(@as(i64, key.int))),\n            .null_val => 0,")
code = code.replace("            .int => return lhs.int == rhs.int,", "            .int => return lhs.int == rhs.int,\n            .null_val => return rhs == .null_val,")
code = code.replace("        .column_compare => {\n            const cmp = expr.column_compare;", "        .compare_subquery => unreachable,\n        .column_compare => {\n            const cmp = expr.column_compare;")
code = code.replace("        .and_expr => |*a| {\n            return try_extract_index_condition(a.left.*, table) orelse try_extract_index_condition(a.right.*, table);", "        .compare_subquery => return null,\n        .and_expr => |*a| {\n            return try_extract_index_condition(a.left.*, table) orelse try_extract_index_condition(a.right.*, table);")
code = code.replace("        .and_expr => |*a| {\n            var new_expr = expr;\n            new_expr.and_expr.left = try copy_expression(allocator, a.left.*);\n            new_expr.and_expr.right = try copy_expression(allocator, a.right.*);\n            return new_expr;\n        }", "        .and_expr => |*a| {\n            var new_expr = expr;\n            new_expr.and_expr.left = try copy_expression(allocator, a.left.*);\n            new_expr.and_expr.right = try copy_expression(allocator, a.right.*);\n            return new_expr;\n        },\n        .compare_subquery => return expr,")


with open("src/query/executor.zig", "w") as f:
    f.write(code)

with open("src/query/executor/in_memory_insert.zig", "r") as f:
    code = f.read()
code = code.replace("var inserted: i32 = 0;", "var inserted: u64 = 0;")
code = code.replace(".int = inserted", ".int = @intCast(inserted)")
with open("src/query/executor/in_memory_insert.zig", "w") as f:
    f.write(code)

with open("src/server/execution.zig", "r") as f:
    code = f.read()
code = code.replace(".child = &base_executor,", ".child = base_executor,")
with open("src/server/execution.zig", "w") as f:
    f.write(code)
