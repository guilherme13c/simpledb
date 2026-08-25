const std = @import("std");
const Lexer = @import("../../src/query/lexer.zig").Lexer;
const TokenType = @import("../../src/query/lexer.zig").TokenType;

fn lexAll(input: []const u8) std.ArrayList(struct { t: TokenType, text: []const u8 }) {
    var list = std.ArrayList(struct { t: TokenType, text: []const u8 }).empty;
    var lexer = Lexer.init(input);
    while (true) {
        const tok = lexer.next_token();
        if (tok.token_type == .EOF) break;
        list.append(std.testing.allocator, .{ .t = tok.token_type, .text = tok.text }) catch {};
    }
    return list;
}

test "lexer: all single-char tokens" {
    const cases = [_]struct { src: []const u8, t: TokenType }{
        .{ .src = "(", .t = .LParen },
        .{ .src = ")", .t = .RParen },
        .{ .src = ",", .t = .Comma },
        .{ .src = ";", .t = .Semicolon },
        .{ .src = "*", .t = .Asterisk },
        .{ .src = "=", .t = .Equals },
    };
    for (cases) |c| {
        var lexer = Lexer.init(c.src);
        const tok = lexer.next_token();
        try std.testing.expectEqual(c.t, tok.token_type);
        try std.testing.expectEqual(c.src, tok.text);
    }
}

test "lexer: comparison operators including two-char" {
    const cases = [_]struct { src: []const u8, t: TokenType }{
        .{ .src = ">", .t = .GreaterThan },
        .{ .src = ">=", .t = .GreaterEquals },
        .{ .src = "<", .t = .LessThan },
        .{ .src = "<=", .t = .LessEquals },
        .{ .src = "!=", .t = .NotEquals },
    };
    for (cases) |c| {
        var lexer = Lexer.init(c.src);
        const tok = lexer.next_token();
        try std.testing.expectEqual(c.t, tok.token_type);
    }
}

test "lexer: lone '!' is an Error token" {
    var lexer = Lexer.init("!");
    const tok = lexer.next_token();
    try std.testing.expectEqual(TokenType.Error, tok.token_type);
}

test "lexer: integer and float literals" {
    var lexer = Lexer.init("42 3.14 0 99999");
    const t1 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Number, t1.token_type);
    try std.testing.expectEqualStrings("42", t1.text);

    const t2 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Number, t2.token_type);
    try std.testing.expectEqualStrings("3.14", t2.text);

    const t3 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Number, t3.token_type);
    try std.testing.expectEqualStrings("0", t3.text);

    const t4 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Number, t4.token_type);
    try std.testing.expectEqualStrings("99999", t4.text);
}

test "lexer: string literal" {
    var lexer = Lexer.init("'hello world'");
    const tok = lexer.next_token();
    try std.testing.expectEqual(TokenType.String, tok.token_type);
    try std.testing.expectEqualStrings("hello world", tok.text);
}

test "lexer: unterminated string is Error" {
    var lexer = Lexer.init("'unterminated");
    const tok = lexer.next_token();
    try std.testing.expectEqual(TokenType.Error, tok.token_type);
}

test "lexer: empty string literal" {
    var lexer = Lexer.init("''");
    const tok = lexer.next_token();
    try std.testing.expectEqual(TokenType.String, tok.token_type);
    try std.testing.expectEqualStrings("", tok.text);
}

test "lexer: keywords are case-insensitive" {
    const pairs = [_]struct { word: []const u8, t: TokenType }{
        .{ .word = "select", .t = .KeywordSelect },
        .{ .word = "SELECT", .t = .KeywordSelect },
        .{ .word = "SeLeCt", .t = .KeywordSelect },
        .{ .word = "from", .t = .KeywordFrom },
        .{ .word = "FROM", .t = .KeywordFrom },
        .{ .word = "where", .t = .KeywordWhere },
        .{ .word = "insert", .t = .KeywordInsert },
        .{ .word = "delete", .t = .KeywordDelete },
        .{ .word = "update", .t = .KeywordUpdate },
        .{ .word = "create", .t = .KeywordCreate },
        .{ .word = "table", .t = .KeywordTable },
        .{ .word = "index", .t = .KeywordIndex },
        .{ .word = "drop", .t = .KeywordDrop },
        .{ .word = "alter", .t = .KeywordAlter },
        .{ .word = "begin", .t = .KeywordBegin },
        .{ .word = "commit", .t = .KeywordCommit },
        .{ .word = "rollback", .t = .KeywordRollback },
        .{ .word = "order", .t = .KeywordOrder },
        .{ .word = "group", .t = .KeywordGroup },
        .{ .word = "by", .t = .KeywordBy },
        .{ .word = "limit", .t = .KeywordLimit },
        .{ .word = "offset", .t = .KeywordOffset },
        .{ .word = "asc", .t = .KeywordAsc },
        .{ .word = "desc", .t = .KeywordDesc },
        .{ .word = "join", .t = .KeywordJoin },
        .{ .word = "on", .t = .KeywordOn },
        .{ .word = "left", .t = .KeywordLeft },
        .{ .word = "right", .t = .KeywordRight },
        .{ .word = "full", .t = .KeywordFull },
        .{ .word = "outer", .t = .KeywordOuter },
        .{ .word = "null", .t = .KeywordNull },
        .{ .word = "into", .t = .KeywordInto },
        .{ .word = "values", .t = .KeywordValues },
        .{ .word = "set", .t = .KeywordSet },
        .{ .word = "and", .t = .KeywordAnd },
        .{ .word = "count", .t = .KeywordCount },
        .{ .word = "sum", .t = .KeywordSum },
        .{ .word = "min", .t = .KeywordMin },
        .{ .word = "max", .t = .KeywordMax },
        .{ .word = "avg", .t = .KeywordAvg },
        .{ .word = "int", .t = .KeywordInt },
        .{ .word = "varchar", .t = .KeywordVarchar },
        .{ .word = "bool", .t = .KeywordBool },
        .{ .word = "float", .t = .KeywordFloat },
        .{ .word = "timestamp", .t = .KeywordTimestamp },
        .{ .word = "json", .t = .KeywordJson },
        .{ .word = "uuid", .t = .KeywordUuid },
        .{ .word = "signed_int", .t = .KeywordSignedInt },
        .{ .word = "hash", .t = .KeywordHash },
        .{ .word = "btree", .t = .KeywordBtree },
        .{ .word = "with", .t = .KeywordWith },
        .{ .word = "as", .t = .KeywordAs },
        .{ .word = "explain", .t = .KeywordExplain },
        .{ .word = "prepare", .t = .KeywordPrepare },
        .{ .word = "over", .t = .KeywordOver },
        .{ .word = "partition", .t = .KeywordPartition },
        .{ .word = "row_number", .t = .KeywordRowNumber },
        .{ .word = "rank", .t = .KeywordRank },
        .{ .word = "having", .t = .KeywordHaving },
        .{ .word = "using", .t = .KeywordUsing },
        .{ .word = "add", .t = .KeywordAdd },
        .{ .word = "rename", .t = .KeywordRename },
        .{ .word = "column", .t = .KeywordColumn },
        .{ .word = "to", .t = .KeywordTo },
    };
    for (pairs) |p| {
        var lexer = Lexer.init(p.word);
        const tok = lexer.next_token();
        try std.testing.expectEqual(p.t, tok.token_type);
    }
}

test "lexer: identifiers (including underscore and dot)" {
    const cases = [_]struct { src: []const u8, expected: []const u8 }{
        .{ .src = "users", .expected = "users" },
        .{ .src = "user_id", .expected = "user_id" },
        .{ .src = "tbl.col", .expected = "tbl.col" },
        .{ .src = "a1b2", .expected = "a1b2" },
    };
    for (cases) |c| {
        var lexer = Lexer.init(c.src);
        const tok = lexer.next_token();
        try std.testing.expectEqual(TokenType.Identifier, tok.token_type);
        try std.testing.expectEqualStrings(c.expected, tok.text);
    }
}

test "lexer: whitespace is skipped (space, tab, newline, CR)" {
    var lexer = Lexer.init("  \t\n\r x");
    const tok = lexer.next_token();
    try std.testing.expectEqual(TokenType.Identifier, tok.token_type);
    try std.testing.expectEqualStrings("x", tok.text);
}

test "lexer: EOF on empty and whitespace-only input" {
    var lexer1 = Lexer.init("");
    try std.testing.expectEqual(TokenType.EOF, lexer1.next_token().token_type);

    var lexer2 = Lexer.init("   \t\n");
    try std.testing.expectEqual(TokenType.EOF, lexer2.next_token().token_type);
}

test "lexer: unknown character yields Error" {
    var lexer = Lexer.init("@");
    const tok = lexer.next_token();
    try std.testing.expectEqual(TokenType.Error, tok.token_type);
}

test "lexer: full statement token stream" {
    var lexer = Lexer.init("SELECT id, name FROM users WHERE age >= 18;");
    const expected = [_]TokenType{
        .KeywordSelect, .Identifier,   .Comma,      .Identifier,    .KeywordFrom,
        .Identifier,    .KeywordWhere, .Identifier, .GreaterEquals, .Number,
        .Semicolon,
    };
    for (expected) |t| {
        const tok = lexer.next_token();
        try std.testing.expectEqual(t, tok.token_type);
    }
    try std.testing.expectEqual(TokenType.EOF, lexer.next_token().token_type);
}
