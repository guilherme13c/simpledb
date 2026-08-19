import os

with open("src/server/execution.zig", "r") as f:
    code = f.read()

code = code.replace("right_table_schema", "right_table.schema")

with open("src/server/execution.zig", "w") as f:
    f.write(code)

with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace(".int => {},", ".int => {},\n            .null_val => {},")
code = code.replace(".limit => |e| return try e.next(),", ".limit => |e| return try e.next(),\n            .in_memory_scan => |e| return try e.next(),\n            .in_memory_insert => |e| return try e.next(),")

with open("src/query/executor.zig", "w") as f:
    f.write(code)

