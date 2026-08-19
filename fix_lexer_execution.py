with open("src/query/lexer.zig", "r") as f:
    content = f.read()

content = content.replace(
"""            if (case_insensitive_eq(text, "EXPLAIN")) return .{ .token_type = .KeywordExplain,
    KeywordWith,
    KeywordAs, .text = text };""",
"""            if (case_insensitive_eq(text, "EXPLAIN")) return .{ .token_type = .KeywordExplain, .text = text };
            if (case_insensitive_eq(text, "WITH")) return .{ .token_type = .KeywordWith, .text = text };
            if (case_insensitive_eq(text, "AS")) return .{ .token_type = .KeywordAs, .text = text };"""
)
with open("src/query/lexer.zig", "w") as f:
    f.write(content)

with open("src/server/execution.zig", "r") as f:
    content = f.read()

content = content.replace("} else {", "} else if (false) {") # A hack, but I will inspect the code manually.
with open("src/server/execution.zig", "w") as f:
    f.write(content)
