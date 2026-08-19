import re

# 1. execution.zig
with open("src/server/execution.zig", "r") as f:
    code = f.read()

orig_sig = """pub fn execute_statement(
    allocator: std.mem.Allocator,
    catalog: *Catalog,
    parsed_stmt: ast.Statement,
    txn_ctx: ?*transaction.TransactionContext,
    writer: anytype,
    undo_stack: ?*std.ArrayList(undo.UndoOp),
) !void {"""

new_sig = """pub fn execute_statement(
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

code = code.replace(orig_sig, new_sig)

with open("src/server/execution.zig", "w") as f:
    f.write(code)

# 2. executor.zig
import os
os.system("git checkout src/query/executor.zig")

with open("src/query/executor.zig", "r") as f:
    code = f.read()

# in_memory executors in union
code = code.replace("limit: *LimitExecutor,", "limit: *LimitExecutor,\n    in_memory_scan: *InMemoryScanExecutor,\n    in_memory_insert: *InMemoryInsertExecutor,")
code = code.replace('pub const LimitExecutor = @import("executor/limit.zig").LimitExecutor;', 'pub const LimitExecutor = @import("executor/limit.zig").LimitExecutor;\npub const InMemoryScanExecutor = @import("executor/in_memory_scan.zig").InMemoryScanExecutor;\npub const InMemoryInsertExecutor = @import("executor/in_memory_insert.zig").InMemoryInsertExecutor;')


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

# switches
code = code.replace(".limit => |e| try e.open(),", ".limit => |e| try e.open(),\n            .in_memory_scan => |e| try e.open(),\n            .in_memory_insert => |e| try e.open(),")
code = code.replace(".limit => |e| e.next(),", ".limit => |e| e.next(),\n            .in_memory_scan => |e| e.next(),\n            .in_memory_insert => |e| e.next(),")
code = code.replace(".limit => |e| e.close(),", ".limit => |e| e.close(),\n            .in_memory_scan => |e| e.close(),\n            .in_memory_insert => |e| e.close(),")
code = code.replace(".limit => |e| { e.child.destroy(allocator); allocator.destroy(e); },", ".limit => |e| { e.child.destroy(allocator); allocator.destroy(e); },\n            .in_memory_scan => |e| allocator.destroy(e),\n            .in_memory_insert => |e| { e.child.destroy(allocator); allocator.destroy(e); },")
code = code.replace(".limit => try writer.print(\"{s}-> Limit\\n\", .{indent_buf[0..depth * 2]}),", ".limit => try writer.print(\"{s}-> Limit\\n\", .{indent_buf[0..depth * 2]}),\n            .in_memory_scan => try writer.print(\"{s}-> InMemoryScan\\n\", .{indent_buf[0..depth * 2]}),\n            .in_memory_insert => try writer.print(\"{s}-> InMemoryInsert\\n\", .{indent_buf[0..depth * 2]}),")

with open("src/query/executor.zig", "w") as f:
    f.write(code)

