with open("src/query/executor.zig", "r") as f:
    code = f.read()

# Fix ValueContext.hash
code = code.replace(".int => @as(u64, @bitCast(@as(i64, key.int))),", ".int => @as(u64, @bitCast(@as(i64, key.int))),\n            .null_val => 0,")
# Fix ValueContext.eql (lhs)
code = code.replace("switch (lhs) {\n            .int => return lhs.int == rhs.int,", "switch (lhs) {\n            .int => return lhs.int == rhs.int,\n            .null_val => return rhs == .null_val,")
# Fix try_extract_index_condition
code = code.replace("""        .column_compare => {
            const cmp = expr.column_compare;""", """        .compare_subquery => unreachable,
        .column_compare => {
            const cmp = expr.column_compare;""")

# Try again if the first attempt at compare_subquery failed
code = code.replace("""        .and_expr => |*a| {
            return try_extract_index_condition(a.left.*, table) orelse try_extract_index_condition(a.right.*, table);""", """        .compare_subquery => return null,
        .and_expr => |*a| {
            return try_extract_index_condition(a.left.*, table) orelse try_extract_index_condition(a.right.*, table);""")


with open("src/query/executor.zig", "w") as f:
    f.write(code)

with open("src/storage/in_memory_table.zig", "r") as f:
    code = f.read()

code = code.replace("std.ArrayList([]ast.Value).init(allocator)", "std.ArrayListUnmanaged([]ast.Value).empty")
code = code.replace("std.ArrayList([]ast.Value)", "std.ArrayListUnmanaged([]ast.Value)")
code = code.replace("tuples.deinit()", "tuples.deinit(self.allocator)")
code = code.replace("tuples.append(duped)", "tuples.append(self.allocator, duped)")

with open("src/storage/in_memory_table.zig", "w") as f:
    f.write(code)

