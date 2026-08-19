import os

with open("src/server/execution.zig", "r") as f:
    code = f.read()

code = code.replace("right_num_left_tuples", "right_table.num_tuples.load(.monotonic)")

with open("src/server/execution.zig", "w") as f:
    f.write(code)


with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace(".int => {},", ".int => {},\n            .null_val => {},")
code = code.replace(".limit => |e| try e.next(),", ".limit => |e| try e.next(),\n            .in_memory_scan => |e| try e.next(),\n            .in_memory_insert => |e| try e.next(),")

with open("src/query/executor.zig", "w") as f:
    f.write(code)

