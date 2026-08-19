with open("src/server/execution.zig", "r") as f:
    code = f.read()

# For delete
code = code.replace("""                var delete_exec = exec.DeleteExecutor{
                    .table = table,
                    .child = base_executor,
                    .txn_ctx = txn_ctx,
                    .allocator = allocator,
                };""", """                var delete_exec = exec.DeleteExecutor{
                    .table = table,
                    .child = &base_executor,
                    .txn_ctx = txn_ctx,
                    .allocator = allocator,
                };""")

# For update
code = code.replace("""                var update_exec = exec.UpdateExecutor{
                    .table = table,
                    .child = base_executor,
                    .column_name = u.column_name,
                    .new_value = u.value,
                    .txn_ctx = txn_ctx,
                    .allocator = allocator,
                };""", """                var update_exec = exec.UpdateExecutor{
                    .table = table,
                    .child = &base_executor,
                    .column_name = u.column_name,
                    .new_value = u.value,
                    .txn_ctx = txn_ctx,
                    .allocator = allocator,
                };""")

with open("src/server/execution.zig", "w") as f:
    f.write(code)
