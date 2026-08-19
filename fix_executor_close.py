with open("src/query/executor.zig", "r") as f:
    code = f.read()

code = code.replace(".in_memory_insert => e.close(),", ".window => e.close(),\n            .in_memory_insert => e.close(),")

with open("src/query/executor.zig", "w") as f:
    f.write(code)
