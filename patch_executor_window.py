with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace("pub const AggregateExecutor = @import(\"executor/aggregate.zig\").AggregateExecutor;", "pub const AggregateExecutor = @import(\"executor/aggregate.zig\").AggregateExecutor;\npub const WindowExecutor = @import(\"executor/window.zig\").WindowExecutor;")

code = code.replace("in_memory_insert: *InMemoryInsertExecutor,", "in_memory_insert: *InMemoryInsertExecutor,\n    window: *WindowExecutor,")

code = code.replace(".in_memory_insert => |e| {", ".window => |e| {\n                try e.close();\n            },\n            .in_memory_insert => |e| {")

code = code.replace(".in_memory_insert => try e.open(),", ".window => try e.open(),\n            .in_memory_insert => try e.open(),")

code = code.replace(".in_memory_insert => return e.next(),", ".window => return e.next(),\n            .in_memory_insert => return e.next(),")

code = code.replace(".in_memory_insert => |e| {\n                try writer.print(\"{s}-> InMemoryInsert\\n\", .{indent});\n                try e.child.explain(writer, depth + 1);\n            },", ".in_memory_insert => |e| {\n                try writer.print(\"{s}-> InMemoryInsert\\n\", .{indent});\n                try e.child.explain(writer, depth + 1);\n            },\n            .window => |e| try e.explain(writer, depth),")

with open("src/query/executor.zig", "w") as f:
    f.write(code)

with open("src/server/execution.zig", "r") as f:
    code = f.read()

win_exec_init = """
                var win_exec: exec.WindowExecutor = undefined;
                if (s.window_functions) |wfs| {
                    win_exec = exec.WindowExecutor{
                        .child = &base_executor,
                        .window_functions = wfs,
                        .input_schema = current_schema,
                        .allocator = allocator,
                    };
                    base_executor = .{ .window = &win_exec };
                }

                var project_exec: exec.ProjectExecutor = undefined;"""

code = code.replace("                var project_exec: exec.ProjectExecutor = undefined;", win_exec_init)

# Modify the ProjectExecutor creation to include window_functions length
project_setup = """                } else if (s.columns) |cols| {
                    const num_win_funcs = if (s.window_functions) |wfs| wfs.len else 0;
                    col_indices = try allocator.alloc(usize, cols.len + num_win_funcs);
                    for (cols, 0..) |col_name, i| {
                        col_indices.?[i] = exec.resolve_column(current_schema, col_name) orelse return error.ColumnNotFound;
                    }
                    for (0..num_win_funcs) |i| {
                        col_indices.?[cols.len + i] = current_schema.len + i;
                    }
                    project_exec = exec.ProjectExecutor{
                        .child = &base_executor,
                        .column_indices = col_indices.?,
                        .allocator = allocator,
                    };
                    final_executor = .{ .project = &project_exec };
                }"""

# We replace the original } else if (s.columns) |cols| { ... }
start_idx = code.find("} else if (s.columns) |cols| {")
end_idx = code.find("final_executor = .{ .project = &project_exec };", start_idx)
end_idx = code.find("}", end_idx) + 1

code = code[:start_idx] + project_setup + code[end_idx:]

with open("src/server/execution.zig", "w") as f:
    f.write(code)
