with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace(".int => |v| .{ .int = v },", ".int => |v| .{ .int = v },\n        .null_val => .{ .null_val = {} },")

code = code.replace("""        .column_compare => {
            const cmp = expr.column_compare;""", """        .compare_subquery => unreachable,
        .column_compare => {
            const cmp = expr.column_compare;""")

with open("src/query/executor.zig", "w") as f:
    f.write(code)

with open("src/storage/in_memory_table.zig", "r") as f:
    code = f.read()
code = code.replace(".is_primary_key = col.is_primary_key,", "")
with open("src/storage/in_memory_table.zig", "w") as f:
    f.write(code)
