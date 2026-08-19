with open("src/query/executor.zig", "r") as f:
    lines = f.readlines()

new_lines = []
for line in lines:
    if "switch (expr) {" in line:
        new_lines.append(line)
        new_lines.append("        .compare_subquery => unreachable,\n")
    else:
        new_lines.append(line)

with open("src/query/executor.zig", "w") as f:
    f.writelines(new_lines)


with open("src/server/execution.zig", "r") as f:
    lines = f.readlines()

new_lines = []
for i, line in enumerate(lines):
    if ".child = base_executor," in line and "var base_executor" not in line:
        new_lines.append(line.replace(".child = base_executor,", ".child = &base_executor,"))
    else:
        new_lines.append(line)

with open("src/server/execution.zig", "w") as f:
    f.writelines(new_lines)
