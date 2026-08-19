import os
for filename in ["src/query/parser.zig", "src/tests.zig"]:
    with open(filename, "r") as f:
        code = f.read()
    code = code.replace(".aggregates = aggregates,", ".aggregates = aggregates, .window_functions = null,")
    code = code.replace(".aggregates = null,", ".aggregates = null, .window_functions = null,")
    with open(filename, "w") as f:
        f.write(code)
