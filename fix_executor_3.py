with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace("""pub fn free_value(allocator: std.mem.Allocator, val: ast.Value) void {
    return switch (val) {
        .int => {},""", """pub fn free_value(allocator: std.mem.Allocator, val: ast.Value) void {
    return switch (val) {
        .int => {},
        .null_val => {},""")

code = code.replace("""        .column_compare => {
            const cmp = expr.column_compare;""", """        .compare_subquery => unreachable,
        .column_compare => {
            const cmp = expr.column_compare;""")

with open("src/query/executor.zig", "w") as f:
    f.write(code)
