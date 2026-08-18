const std = @import("std");

pub const TokenType = enum {
    KeywordCreate,
    KeywordTable,
    KeywordIndex,
    KeywordDrop,
    KeywordInsert,
    KeywordInto,
    KeywordValues,
    KeywordSelect,
    KeywordFrom,
    KeywordWhere,
    KeywordAnd,
    KeywordDelete,
    KeywordUpdate,
    KeywordSet,
    KeywordJoin,
    KeywordOn,
    KeywordBegin,
    KeywordCommit,
    KeywordRollback,
    KeywordExplain,
    KeywordInt,
    KeywordVarchar,
    KeywordBool,
    KeywordFloat,
    KeywordTimestamp,
    KeywordJson,
    KeywordUuid,
    KeywordSignedInt,
    KeywordCount,
    KeywordSum,
    KeywordMin,
    KeywordMax,
    KeywordAvg,
    KeywordGroup,
    KeywordBy,
    KeywordOrder,
    KeywordAsc,
    KeywordDesc,
    KeywordLimit,
    KeywordOffset,
    Identifier,
    Number,
    String,
    LParen,
    RParen,
    Comma,
    Semicolon,
    Equals,
    NotEquals,
    GreaterThan,
    GreaterEquals,
    LessThan,
    LessEquals,
    Asterisk,
    EOF,
    Error,
};

pub const Token = struct {
    token_type: TokenType,
    text: []const u8,
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
        };
    }

    fn skip_whitespace(self: *Lexer) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    pub fn next_token(self: *Lexer) Token {
        self.skip_whitespace();
        if (self.pos >= self.input.len) {
            return .{ .token_type = .EOF, .text = "" };
        }

        const c = self.input[self.pos];

        // Single character tokens
        switch (c) {
            '(' => { self.pos += 1; return .{ .token_type = .LParen, .text = self.input[self.pos-1 .. self.pos] }; },
            ')' => { self.pos += 1; return .{ .token_type = .RParen, .text = self.input[self.pos-1 .. self.pos] }; },
            ',' => { self.pos += 1; return .{ .token_type = .Comma, .text = self.input[self.pos-1 .. self.pos] }; },
            ';' => { self.pos += 1; return .{ .token_type = .Semicolon, .text = self.input[self.pos-1 .. self.pos] }; },
            '*' => { self.pos += 1; return .{ .token_type = .Asterisk, .text = self.input[self.pos-1 .. self.pos] }; },
            '=' => { self.pos += 1; return .{ .token_type = .Equals, .text = self.input[self.pos-1 .. self.pos] }; },
            '>' => {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .token_type = .GreaterEquals, .text = self.input[self.pos-2 .. self.pos] };
                }
                self.pos += 1;
                return .{ .token_type = .GreaterThan, .text = self.input[self.pos-1 .. self.pos] };
            },
            '<' => {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .token_type = .LessEquals, .text = self.input[self.pos-2 .. self.pos] };
                }
                self.pos += 1;
                return .{ .token_type = .LessThan, .text = self.input[self.pos-1 .. self.pos] };
            },
            '!' => {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .{ .token_type = .NotEquals, .text = self.input[self.pos-2 .. self.pos] };
                }
                self.pos += 1;
                return .{ .token_type = .Error, .text = self.input[self.pos-1 .. self.pos] };
            },
            '\'' => {
                const start = self.pos;
                self.pos += 1; // skip quote
                while (self.pos < self.input.len and self.input[self.pos] != '\'') {
                    self.pos += 1;
                }
                if (self.pos < self.input.len) {
                    self.pos += 1; // skip closing quote
                    return .{ .token_type = .String, .text = self.input[start+1 .. self.pos-1] };
                }
                return .{ .token_type = .Error, .text = self.input[start..self.pos] };
            },
            else => {}
        }

        // Numbers
        if (is_digit(c)) {
            const start = self.pos;
            while (self.pos < self.input.len and is_digit(self.input[self.pos])) {
                self.pos += 1;
            }
            return .{ .token_type = .Number, .text = self.input[start..self.pos] };
        }

        // Identifiers and Keywords
        if (is_alpha(c)) {
            const start = self.pos;
            while (self.pos < self.input.len and (is_alpha(self.input[self.pos]) or is_digit(self.input[self.pos]) or self.input[self.pos] == '_' or self.input[self.pos] == '.')) {
                self.pos += 1;
            }
            const text = self.input[start..self.pos];
            
            // Check keywords (case-insensitive)
            if (case_insensitive_eq(text, "CREATE")) return .{ .token_type = .KeywordCreate, .text = text };
            if (case_insensitive_eq(text, "TABLE")) return .{ .token_type = .KeywordTable, .text = text };
            if (case_insensitive_eq(text, "DROP")) return .{ .token_type = .KeywordDrop, .text = text };
            if (case_insensitive_eq(text, "INSERT")) return .{ .token_type = .KeywordInsert, .text = text };
            if (case_insensitive_eq(text, "INTO")) return .{ .token_type = .KeywordInto, .text = text };
            if (case_insensitive_eq(text, "VALUES")) return .{ .token_type = .KeywordValues, .text = text };
            if (case_insensitive_eq(text, "SELECT")) return .{ .token_type = .KeywordSelect, .text = text };
            if (case_insensitive_eq(text, "FROM")) return .{ .token_type = .KeywordFrom, .text = text };
            if (case_insensitive_eq(text, "WHERE")) return .{ .token_type = .KeywordWhere, .text = text };
            if (case_insensitive_eq(text, "AND")) return .{ .token_type = .KeywordAnd, .text = text };
            if (case_insensitive_eq(text, "DELETE")) return .{ .token_type = .KeywordDelete, .text = text };
            if (case_insensitive_eq(text, "UPDATE")) return .{ .token_type = .KeywordUpdate, .text = text };
            if (case_insensitive_eq(text, "SET")) return .{ .token_type = .KeywordSet, .text = text };
            if (case_insensitive_eq(text, "JOIN")) return .{ .token_type = .KeywordJoin, .text = text };
            if (case_insensitive_eq(text, "ON")) return .{ .token_type = .KeywordOn, .text = text };
            if (case_insensitive_eq(text, "BEGIN")) return .{ .token_type = .KeywordBegin, .text = text };
            if (case_insensitive_eq(text, "COMMIT")) return .{ .token_type = .KeywordCommit, .text = text };
            if (case_insensitive_eq(text, "ROLLBACK")) return .{ .token_type = .KeywordRollback, .text = text };
            if (case_insensitive_eq(text, "EXPLAIN")) return .{ .token_type = .KeywordExplain, .text = text };
            if (case_insensitive_eq(text, "INT")) return .{ .token_type = .KeywordInt, .text = text };
            if (case_insensitive_eq(text, "VARCHAR")) return .{ .token_type = .KeywordVarchar, .text = text };
            if (case_insensitive_eq(text, "BOOL")) return .{ .token_type = .KeywordBool, .text = text };
            if (case_insensitive_eq(text, "FLOAT")) return .{ .token_type = .KeywordFloat, .text = text };
            if (case_insensitive_eq(text, "TIMESTAMP")) return .{ .token_type = .KeywordTimestamp, .text = text };
            if (case_insensitive_eq(text, "JSON")) return .{ .token_type = .KeywordJson, .text = text };
            if (case_insensitive_eq(text, "UUID")) return .{ .token_type = .KeywordUuid, .text = text };
            if (case_insensitive_eq(text, "SIGNED_INT")) return .{ .token_type = .KeywordSignedInt, .text = text };
            if (case_insensitive_eq(text, "COUNT")) return .{ .token_type = .KeywordCount, .text = text };
            if (case_insensitive_eq(text, "SUM")) return .{ .token_type = .KeywordSum, .text = text };
            if (case_insensitive_eq(text, "MIN")) return .{ .token_type = .KeywordMin, .text = text };
            if (case_insensitive_eq(text, "MAX")) return .{ .token_type = .KeywordMax, .text = text };
            if (case_insensitive_eq(text, "AVG")) return .{ .token_type = .KeywordAvg, .text = text };
            if (case_insensitive_eq(text, "GROUP")) return .{ .token_type = .KeywordGroup, .text = text };
            if (case_insensitive_eq(text, "BY")) return .{ .token_type = .KeywordBy, .text = text };
            if (case_insensitive_eq(text, "ORDER")) return .{ .token_type = .KeywordOrder, .text = text };
            if (case_insensitive_eq(text, "ASC")) return .{ .token_type = .KeywordAsc, .text = text };
            if (case_insensitive_eq(text, "DESC")) return .{ .token_type = .KeywordDesc, .text = text };
            if (case_insensitive_eq(text, "LIMIT")) return .{ .token_type = .KeywordLimit, .text = text };
            if (case_insensitive_eq(text, "OFFSET")) return .{ .token_type = .KeywordOffset, .text = text };
            
            return .{ .token_type = .Identifier, .text = text };
        }

        self.pos += 1;
        return .{ .token_type = .Error, .text = self.input[self.pos-1 .. self.pos] };
    }

    fn is_digit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn is_alpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn case_insensitive_eq(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            const ca = if (a[i] >= 'a' and a[i] <= 'z') a[i] - 32 else a[i];
            const cb = if (b[i] >= 'a' and b[i] <= 'z') b[i] - 32 else b[i];
            if (ca != cb) return false;
        }
        return true;
    }
};

test "lexer basic" {
    var lexer = Lexer.init("SELECT * FROM users WHERE key = 1;");
    
    const t1 = lexer.next_token();
    try std.testing.expectEqual(TokenType.KeywordSelect, t1.token_type);
    
    const t2 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Asterisk, t2.token_type);
    
    const t3 = lexer.next_token();
    try std.testing.expectEqual(TokenType.KeywordFrom, t3.token_type);
    
    const t4 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Identifier, t4.token_type);
    try std.testing.expectEqualStrings("users", t4.text);
    
    const t5 = lexer.next_token();
    try std.testing.expectEqual(TokenType.KeywordWhere, t5.token_type);
    
    const t6 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Identifier, t6.token_type);
    try std.testing.expectEqualStrings("key", t6.text);
    
    const t7 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Equals, t7.token_type);
    
    const t8 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Number, t8.token_type);
    try std.testing.expectEqualStrings("1", t8.text);
    
    const t9 = lexer.next_token();
    try std.testing.expectEqual(TokenType.Semicolon, t9.token_type);
}
