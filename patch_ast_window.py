with open("src/query/ast.zig", "r") as f:
    code = f.read()

window_struct = """
pub const WindowFuncType = enum {
    row_number,
    rank,
    sum,
    count,
};

pub const WindowFunctionExpr = struct {
    func: WindowFuncType,
    arg_column: ?[]const u8,
    partition_by: ?[]const u8,
    order_by: ?[]const u8,
    is_desc: bool,
};

pub const Cte = struct {"""

code = code.replace("pub const Cte = struct {", window_struct)

code = code.replace("aggregates: ?[]const AggregateExpr,", "aggregates: ?[]const AggregateExpr,\n        window_functions: ?[]const WindowFunctionExpr,")

with open("src/query/ast.zig", "w") as f:
    f.write(code)

with open("src/query/lexer.zig", "r") as f:
    code = f.read()

keywords_enum = """    KeywordUpdate,
    KeywordOver,
    KeywordPartition,
    KeywordRowNumber,
    KeywordRank,"""

code = code.replace("    KeywordUpdate,", keywords_enum)

keywords_match = """            if (case_insensitive_eq(text, "UPDATE")) return .{ .token_type = .KeywordUpdate, .text = text };
            if (case_insensitive_eq(text, "OVER")) return .{ .token_type = .KeywordOver, .text = text };
            if (case_insensitive_eq(text, "PARTITION")) return .{ .token_type = .KeywordPartition, .text = text };
            if (case_insensitive_eq(text, "ROW_NUMBER")) return .{ .token_type = .KeywordRowNumber, .text = text };
            if (case_insensitive_eq(text, "RANK")) return .{ .token_type = .KeywordRank, .text = text };"""

code = code.replace("            if (case_insensitive_eq(text, \"UPDATE\")) return .{ .token_type = .KeywordUpdate, .text = text };", keywords_match)

with open("src/query/lexer.zig", "w") as f:
    f.write(code)
