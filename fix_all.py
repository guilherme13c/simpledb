import re

# 1. Fix extract_schema in execution.zig
with open("src/server/execution.zig", "r") as f:
    code = f.read()

code = code.replace("for (table_schema) |table_col| {", "for (table.schema) |table_col| {")
code = code.replace("for (table_schema, 0..) |table_col, i| {", "for (table.schema, 0..) |table_col, i| {")
code = code.replace("allocator.alloc(ast.ColumnDef, table_schema.len)", "allocator.alloc(ast.ColumnDef, table.schema.len)")

with open("src/server/execution.zig", "w") as f:
    f.write(code)

# 2. Fix executor.zig
with open("src/query/executor.zig", "r") as f:
    code = f.read()

# null_val in dupe_value
code = code.replace(".int => .{ .int = val.int },", ".int => .{ .int = val.int },\n            .null_val => .{ .null_val = {} },")
# null_val in format_tuple
code = code.replace("            .int => try writer.print(\"{d}\", .{v.int}),", "            .int => try writer.print(\"{d}\", .{v.int}),\n            .null_val => try writer.print(\"NULL\", .{}),")
# null_val in ValueContext.hash
code = code.replace(".int => @as(u64, @bitCast(@as(i64, key.int))),", ".int => @as(u64, @bitCast(@as(i64, key.int))),\n            .null_val => 0,")
# null_val in ValueContext.eql
code = code.replace("return a.int == b.int;", "return a.int == b.int;\n            .null_val => return b == .null_val,")
# null_val in compare_values
code = code.replace(".int => return compare_ints(left.int, right.int, op),", ".int => return compare_ints(left.int, right.int, op),\n        .null_val => return false,")


# in_memory executors in switches
def add_to_switch(switch_start, replacements):
    global code
    code = code.replace(switch_start, switch_start + "\n" + replacements)

# open
code = code.replace(".limit => |e| try e.open(),", ".limit => |e| try e.open(),\n            .in_memory_scan => |e| try e.open(),\n            .in_memory_insert => |e| try e.open(),")
# next
code = code.replace(".limit => |e| e.next(),", ".limit => |e| e.next(),\n            .in_memory_scan => |e| e.next(),\n            .in_memory_insert => |e| e.next(),")
# close
code = code.replace(".limit => |e| e.close(),", ".limit => |e| e.close(),\n            .in_memory_scan => |e| e.close(),\n            .in_memory_insert => |e| e.close(),")
# destroy
code = code.replace(".limit => |e| { e.child.destroy(allocator); allocator.destroy(e); },", ".limit => |e| { e.child.destroy(allocator); allocator.destroy(e); },\n            .in_memory_scan => |e| allocator.destroy(e),\n            .in_memory_insert => |e| { e.child.destroy(allocator); allocator.destroy(e); },")
# explain
code = code.replace(".limit => try writer.print(\"{s}-> Limit\\n\", .{indent_buf[0..depth * 2]}),", ".limit => try writer.print(\"{s}-> Limit\\n\", .{indent_buf[0..depth * 2]}),\n            .in_memory_scan => try writer.print(\"{s}-> InMemoryScan\\n\", .{indent_buf[0..depth * 2]}),\n            .in_memory_insert => try writer.print(\"{s}-> InMemoryInsert\\n\", .{indent_buf[0..depth * 2]}),")

with open("src/query/executor.zig", "w") as f:
    f.write(code)

