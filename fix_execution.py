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

start_idx = code.find("} else if (s.columns) |cols| {")
# Instead of searching for "}", we will find the entire original block using string replacement!
orig_block = """} else if (s.columns) |cols| {
                    col_indices = try allocator.alloc(usize, cols.len);
                    for (cols, 0..) |col_name, i| {
                        col_indices.?[i] = exec.resolve_column(current_schema, col_name) orelse return error.ColumnNotFound;
                    }
                    project_exec = exec.ProjectExecutor{
                        .child = &base_executor,
                        .column_indices = col_indices.?,
                        .allocator = allocator,
                    };
                    final_executor = .{ .project = &project_exec };
                }"""

code = code.replace(orig_block, project_setup)
with open("src/server/execution.zig", "w") as f:
    f.write(code)
