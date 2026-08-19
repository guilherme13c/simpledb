import re

with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace(".int => |val| try writer.print(\"{d}\", .{val}),", ".int => |val| try writer.print(\"{d}\", .{val}),\n            .null_val => try writer.print(\"NULL\", .{}),")

code = code.replace(".limit => |e| {\n                try writer.print(\"{s}-> Limit\\n\", .{indent});\n                try e.child.explain(writer, depth + 1);\n            },", ".limit => |e| {\n                try writer.print(\"{s}-> Limit\\n\", .{indent});\n                try e.child.explain(writer, depth + 1);\n            },\n            .in_memory_scan => try writer.print(\"{s}-> InMemoryScan\\n\", .{indent}),\n            .in_memory_insert => |e| {\n                try writer.print(\"{s}-> InMemoryInsert\\n\", .{indent});\n                try e.child.explain(writer, depth + 1);\n            },")

with open("src/query/executor.zig", "w") as f:
    f.write(code)
