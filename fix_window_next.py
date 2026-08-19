with open("src/query/executor/window.zig", "r") as f:
    code = f.read()

replacement = """    pub fn next(self: *@This()) !?[]ast.Value {
        if (self.current_idx >= self.tuples.items.len) return null;
        const res = self.tuples.items[self.current_idx];
        self.current_idx += 1;
        
        var duped = try self.allocator.alloc(ast.Value, res.len);
        for (res, 0..) |v, i| {
            duped[i] = try exec.dupe_value(self.allocator, v);
        }
        return duped;
    }"""

import re
code = re.sub(r'    pub fn next\(self: \*\@This\(\)\) \!\?\[\]ast\.Value \{.*?    \}', replacement, code, flags=re.DOTALL)

with open("src/query/executor/window.zig", "w") as f:
    f.write(code)
