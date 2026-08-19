with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace(".in_memory_scan => try e.open(),", ".in_memory_scan => try e.open(),\n            .window => try e.open(),")
code = code.replace(".in_memory_scan => return e.next(),", ".in_memory_scan => return e.next(),\n            .window => return e.next(),")
code = code.replace(".in_memory_scan => e.close(),", ".in_memory_scan => e.close(),\n            .window => e.close(),")

with open("src/query/executor.zig", "w") as f:
    f.write(code)
