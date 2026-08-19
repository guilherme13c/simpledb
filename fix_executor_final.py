with open("src/query/executor.zig", "r") as f:
    code = f.read()

# 1. hash
code = code.replace(".int => |v| hasher.update(std.mem.asBytes(&v)),", ".int => |v| hasher.update(std.mem.asBytes(&v)),\n            .null_val => return 0,")

# 2. compare_values
code = code.replace(".int => |a| {", ".null_val => return false,\n        .int => |a| {")

# 3. try_extract_index_condition
code = code.replace("        .column_compare => {\\n            const cmp = expr.column_compare;", "        .compare_subquery => return null,\n        .column_compare => {\n            const cmp = expr.column_compare;")
code = code.replace("        .column_compare => {\n            const cmp = expr.column_compare;", "        .compare_subquery => return null,\n        .column_compare => {\n            const cmp = expr.column_compare;")
# wait, there are multiple try_extract_index_condition? evaluate_expression is one.
# Let's just blindly replace them if they are missing.
if ".compare_subquery =>" not in code:
    code = code.replace("        .column_compare => {", "        .compare_subquery => unreachable,\n        .column_compare => {", 1) # evaluate_expression
    code = code.replace("        .column_compare => {", "        .compare_subquery => return null,\n        .column_compare => {", 1) # try_extract_index_condition
    code = code.replace("        .column_compare => {", "        .compare_subquery => return null,\n        .column_compare => {", 1) # another one?
    
# Actually let's use regex
import re
code = re.sub(r'(\s+)\.column_compare => \{', r'\1.compare_subquery => unreachable,\1.column_compare => {', code, count=1)
code = re.sub(r'(\s+)\.column_compare => \{', r'\1.compare_subquery => return null,\1.column_compare => {', code)

code = re.sub(r'(\s+)\.and_expr => \|\*a\| \{', r'\1.compare_subquery => return null,\1.and_expr => |*a| {', code)

with open("src/query/executor.zig", "w") as f:
    f.write(code)

with open("src/server/execution.zig", "r") as f:
    code = f.read()
code = code.replace(".child = base_executor,", ".child = &base_executor,")
with open("src/server/execution.zig", "w") as f:
    f.write(code)

