const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const TokenType = lexer_mod.TokenType;
const ast = @import("ast.zig");

pub const ParserError = error{
    UnexpectedToken,
    InvalidSyntax,
    InvalidNumber,
};

pub const Parser = struct {
    lexer: Lexer,
    current_token: lexer_mod.Token,
    allocator: std.mem.Allocator,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) Parser {
        var p = Parser{
            .lexer = Lexer.init(input),
            .current_token = undefined,
            .allocator = allocator,
        };
        p.advance();
        return p;
    }

    fn advance(self: *Parser) void {
        self.current_token = self.lexer.next_token();
    }

    fn match(self: *Parser, expected: TokenType) !void {
        if (self.current_token.token_type == expected) {
            self.advance();
        } else {
            return error.UnexpectedToken;
        }
    }

    pub fn parse_statement(self: *Parser) !ast.Statement {
        switch (self.current_token.token_type) {
            .KeywordCreate => return self.parse_create(),
            .KeywordDrop => return self.parse_drop(),
            .KeywordInsert => return self.parse_insert(),
            .KeywordSelect => return self.parse_select(),
            .KeywordDelete => return self.parse_delete(),
            .KeywordUpdate => return self.parse_update(),
            .KeywordBegin => {
                self.advance();
                if (self.current_token.token_type == .Semicolon) self.advance();
                return .begin;
            },
            .KeywordCommit => {
                self.advance();
                if (self.current_token.token_type == .Semicolon) self.advance();
                return .commit;
            },
            .KeywordRollback => {
                self.advance();
                if (self.current_token.token_type == .Semicolon) self.advance();
                return .rollback;
            },
            .KeywordExplain => {
                self.advance();
                const stmt_ptr = try self.allocator.create(ast.Statement);
                stmt_ptr.* = try self.parse_statement();
                return .{ .explain = stmt_ptr };
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parse_create(self: *Parser) !ast.Statement {
        try self.match(.KeywordCreate);
        
        if (self.current_token.token_type == .KeywordIndex) {
            self.advance();
            if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
            const index_name = self.current_token.text;
            self.advance();

            try self.match(.KeywordOn);
            if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
            const table_name = self.current_token.text;
            self.advance();

            try self.match(.LParen);
            if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
            const col_name = self.current_token.text;
            self.advance();
            try self.match(.RParen);
            
            if (self.current_token.token_type == .Semicolon) self.advance();

            return .{ .create_index = .{ .index_name = index_name, .table_name = table_name, .column_name = col_name } };
        }
        
        try self.match(.KeywordTable);
        
        if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
        const table_name = self.current_token.text;
        self.advance();

        var columns = std.ArrayList(ast.ColumnDef).empty;
        errdefer columns.deinit(self.allocator);

        if (self.current_token.token_type == .LParen) {
            self.advance();
            
            while (self.current_token.token_type != .RParen) {
                if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
                const col_name = self.current_token.text;
                self.advance();
                
                const col_type = switch (self.current_token.token_type) {
                    .KeywordInt => ast.DataType.int,
                    .KeywordVarchar => ast.DataType.varchar,
                    .KeywordBool => ast.DataType.bool,
                    .KeywordFloat => ast.DataType.float,
                    .KeywordTimestamp => ast.DataType.timestamp,
                    .KeywordJson => ast.DataType.json,
                    .KeywordUuid => ast.DataType.uuid,
                    .KeywordSignedInt => ast.DataType.signed_int,
                    else => return error.UnexpectedToken,
                };
                self.advance();
                
                try columns.append(self.allocator, .{ .name = col_name, .data_type = col_type });
                
                if (self.current_token.token_type == .Comma) {
                    self.advance();
                } else if (self.current_token.token_type != .RParen) {
                    return error.UnexpectedToken;
                }
            }
            try self.match(.RParen);
        }

        if (self.current_token.token_type == .Semicolon) {
            self.advance();
        }

        return .{ .create_table = .{ .table_name = table_name, .columns = try columns.toOwnedSlice(self.allocator) } };
    }

    fn parse_drop(self: *Parser) !ast.Statement {
        try self.match(.KeywordDrop);
        try self.match(.KeywordTable);
        
        if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
        const table_name = self.current_token.text;
        self.advance();

        if (self.current_token.token_type == .Semicolon) {
            self.advance();
        }

        return .{ .drop_table = .{ .table_name = table_name } };
    }

    fn parse_insert(self: *Parser) !ast.Statement {
        try self.match(.KeywordInsert);
        try self.match(.KeywordInto);
        
        if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
        const table_name = self.current_token.text;
        self.advance();

        try self.match(.KeywordValues);
        try self.match(.LParen);
        
        var values = std.ArrayList(ast.Value).empty;
        errdefer values.deinit(self.allocator);
        
        while (self.current_token.token_type != .RParen) {
            if (self.current_token.token_type == .Number) {
                const val = std.fmt.parseInt(u64, self.current_token.text, 10) catch return error.InvalidNumber;
                try values.append(self.allocator, .{ .int = val });
                self.advance();
            } else if (self.current_token.token_type == .String) {
                try values.append(self.allocator, .{ .varchar = self.current_token.text });
                self.advance();
            } else if (self.current_token.token_type == .Identifier) {
                // Check if it's a bool literal
                if (std.mem.eql(u8, self.current_token.text, "true") or std.mem.eql(u8, self.current_token.text, "TRUE")) {
                    try values.append(self.allocator, .{ .bool = true });
                } else if (std.mem.eql(u8, self.current_token.text, "false") or std.mem.eql(u8, self.current_token.text, "FALSE")) {
                    try values.append(self.allocator, .{ .bool = false });
                } else {
                    return error.UnexpectedToken;
                }
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
            
            if (self.current_token.token_type == .Comma) {
                self.advance();
            } else if (self.current_token.token_type != .RParen) {
                return error.UnexpectedToken;
            }
        }

        try self.match(.RParen);

        if (self.current_token.token_type == .Semicolon) {
            self.advance();
        }

        return .{ .insert = .{ .table_name = table_name, .values = try values.toOwnedSlice(self.allocator) } };
    }

    fn parse_select(self: *Parser) !ast.Statement {
        try self.match(.KeywordSelect);
        var columns: ?[]const []const u8 = null;
        var aggregates: ?[]const ast.AggregateExpr = null;

        if (self.current_token.token_type == .Asterisk) {
            self.advance();
        } else {
            var col_list = std.ArrayList([]const u8).empty;
            errdefer col_list.deinit(self.allocator);
            var agg_list = std.ArrayList(ast.AggregateExpr).empty;
            errdefer agg_list.deinit(self.allocator);

            while (true) {
                var is_agg = false;
                var op: ast.AggregateOp = .count;
                
                if (self.current_token.token_type == .KeywordCount) { is_agg = true; op = .count; }
                else if (self.current_token.token_type == .KeywordSum) { is_agg = true; op = .sum; }
                else if (self.current_token.token_type == .KeywordMin) { is_agg = true; op = .min; }
                else if (self.current_token.token_type == .KeywordMax) { is_agg = true; op = .max; }
                else if (self.current_token.token_type == .KeywordAvg) { is_agg = true; op = .avg; }
                
                if (is_agg) {
                    self.advance(); // consume agg kw
                    try self.match(.LParen);
                    
                    var col_name: ?[]const u8 = null;
                    if (self.current_token.token_type == .Asterisk) {
                        self.advance();
                    } else if (self.current_token.token_type == .Identifier) {
                        col_name = self.current_token.text;
                        self.advance();
                    } else {
                        return error.UnexpectedToken;
                    }
                    try self.match(.RParen);
                    
                    try agg_list.append(self.allocator, .{ .op = op, .column = col_name });
                } else if (self.current_token.token_type == .Identifier) {
                    try col_list.append(self.allocator, self.current_token.text);
                    self.advance();
                } else {
                    return error.UnexpectedToken;
                }

                if (self.current_token.token_type == .Comma) {
                    self.advance();
                } else {
                    break;
                }
            }
            if (col_list.items.len > 0) columns = try col_list.toOwnedSlice(self.allocator);
            if (agg_list.items.len > 0) aggregates = try agg_list.toOwnedSlice(self.allocator);
        }

        try self.match(.KeywordFrom);

        if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
        const table_name = self.current_token.text;
        self.advance();

        var join_table: ?[]const u8 = null;
        var join_condition: ?ast.Expression = null;
        if (self.current_token.token_type == .KeywordJoin) {
            self.advance();
            if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
            join_table = self.current_token.text;
            self.advance();
            
            try self.match(.KeywordOn);
            join_condition = try self.parse_expression();
        }

        var condition: ?ast.Expression = null;
        if (self.current_token.token_type == .KeywordWhere) {
            self.advance();
            condition = try self.parse_expression();
        }

        var group_by: ?[]const u8 = null;
        if (self.current_token.token_type == .KeywordGroup) {
            self.advance();
            try self.match(.KeywordBy);
            
            if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
            group_by = self.current_token.text;
            self.advance();
        }

        var order_by: ?[]const u8 = null;
        var is_desc = false;
        if (self.current_token.token_type == .KeywordOrder) {
            self.advance();
            try self.match(.KeywordBy);
            
            if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
            order_by = self.current_token.text;
            self.advance();
            
            if (self.current_token.token_type == .KeywordDesc) {
                is_desc = true;
                self.advance();
            } else if (self.current_token.token_type == .KeywordAsc) {
                self.advance();
            }
        }
        
        var limit: ?usize = null;
        if (self.current_token.token_type == .KeywordLimit) {
            self.advance();
            if (self.current_token.token_type != .Number) return error.UnexpectedToken;
            limit = std.fmt.parseInt(usize, self.current_token.text, 10) catch return error.InvalidNumber;
            self.advance();
        }
        
        var offset: ?usize = null;
        if (self.current_token.token_type == .KeywordOffset) {
            self.advance();
            if (self.current_token.token_type != .Number) return error.UnexpectedToken;
            offset = std.fmt.parseInt(usize, self.current_token.text, 10) catch return error.InvalidNumber;
            self.advance();
        }

        if (self.current_token.token_type == .Semicolon) {
            self.advance();
        }

        return .{ .select = .{ .columns = columns, .aggregates = aggregates, .table_name = table_name, .join_table = join_table, .join_condition = join_condition, .condition = condition, .group_by = group_by, .order_by = order_by, .is_desc = is_desc, .limit = limit, .offset = offset } };
    }

    fn parse_delete(self: *Parser) !ast.Statement {
        try self.match(.KeywordDelete);
        try self.match(.KeywordFrom);

        if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
        const table_name = self.current_token.text;
        self.advance();

        var condition: ?ast.Expression = null;
        if (self.current_token.token_type == .KeywordWhere) {
            self.advance();
            condition = try self.parse_expression();
        }

        if (self.current_token.token_type == .Semicolon) {
            self.advance();
        }

        return .{ .delete = .{ .table_name = table_name, .condition = condition } };
    }

    fn parse_update(self: *Parser) !ast.Statement {
        try self.match(.KeywordUpdate);
        
        if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
        const table_name = self.current_token.text;
        self.advance();

        try self.match(.KeywordSet);

        if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
        const column_name = self.current_token.text;
        self.advance();
        
        try self.match(.Equals);

        var value: ast.Value = undefined;
        if (self.current_token.token_type == .String) {
            value = .{ .varchar = self.current_token.text };
            self.advance();
        } else if (self.current_token.token_type == .Number) {
            const val = std.fmt.parseInt(u64, self.current_token.text, 10) catch return error.InvalidNumber;
            value = .{ .int = val };
            self.advance();
        } else if (self.current_token.token_type == .Identifier) {
            if (std.mem.eql(u8, self.current_token.text, "true") or std.mem.eql(u8, self.current_token.text, "TRUE")) {
                value = .{ .bool = true };
                self.advance();
            } else if (std.mem.eql(u8, self.current_token.text, "false") or std.mem.eql(u8, self.current_token.text, "FALSE")) {
                value = .{ .bool = false };
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
        } else {
            return error.UnexpectedToken;
        }

        var condition: ?ast.Expression = null;
        if (self.current_token.token_type == .KeywordWhere) {
            self.advance();
            condition = try self.parse_expression();
        }

        if (self.current_token.token_type == .Semicolon) {
            self.advance();
        }

        return .{ .update = .{ .table_name = table_name, .column_name = column_name, .value = value, .condition = condition } };
    }

    fn parse_expression(self: *Parser) !ast.Expression {
        const left = try self.parse_compare();

        if (self.current_token.token_type == .KeywordAnd) {
            self.advance();
            const right = try self.parse_expression();

            const left_ptr = try self.allocator.create(ast.Expression);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(ast.Expression);
            right_ptr.* = right;

            return .{ .and_expr = .{ .left = left_ptr, .right = right_ptr } };
        }

        return left;
    }

    fn parse_compare(self: *Parser) !ast.Expression {
        if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
        const column = self.current_token.text;
        self.advance();

        const op: ast.CompareOp = switch (self.current_token.token_type) {
            .Equals => .eq,
            .NotEquals => .neq,
            .GreaterThan => .gt,
            .GreaterEquals => .gte,
            .LessThan => .lt,
            .LessEquals => .lte,
            else => return error.UnexpectedToken,
        };
        self.advance();

        // If it's an identifier that is not a boolean literal, it's a column compare
        if (self.current_token.token_type == .Identifier and
            !std.mem.eql(u8, self.current_token.text, "true") and !std.mem.eql(u8, self.current_token.text, "TRUE") and
            !std.mem.eql(u8, self.current_token.text, "false") and !std.mem.eql(u8, self.current_token.text, "FALSE")) {
            const right_column = self.current_token.text;
            self.advance();
            return .{ .column_compare = .{ .left_column = column, .op = op, .right_column = right_column } };
        }

        // Parse value: number, string, or bool literal
        const value: ast.Value = if (self.current_token.token_type == .Number) blk: {
            const val = std.fmt.parseInt(u64, self.current_token.text, 10) catch return error.InvalidNumber;
            self.advance();
            break :blk .{ .int = val };
        } else if (self.current_token.token_type == .String) blk: {
            const val = self.current_token.text;
            self.advance();
            break :blk .{ .varchar = val };
        } else if (self.current_token.token_type == .Identifier) blk: {
            if (std.mem.eql(u8, self.current_token.text, "true") or std.mem.eql(u8, self.current_token.text, "TRUE")) {
                self.advance();
                break :blk .{ .bool = true };
            } else if (std.mem.eql(u8, self.current_token.text, "false") or std.mem.eql(u8, self.current_token.text, "FALSE")) {
                self.advance();
                break :blk .{ .bool = false };
            } else {
                return error.UnexpectedToken;
            }
        } else {
            return error.UnexpectedToken;
        };

        return .{ .compare = .{ .column = column, .op = op, .value = value } };
    }
};

test "parse create" {
    var parser = Parser.init("CREATE TABLE users (id INT, name VARCHAR);", std.testing.allocator);
    const stmt = try parser.parse_statement();
    defer std.testing.allocator.free(stmt.create_table.columns);
    try std.testing.expect(stmt == .create_table);
    try std.testing.expectEqualStrings("users", stmt.create_table.table_name);
    try std.testing.expectEqual(@as(usize, 2), stmt.create_table.columns.len);
    try std.testing.expectEqualStrings("id", stmt.create_table.columns[0].name);
    try std.testing.expectEqual(ast.DataType.int, stmt.create_table.columns[0].data_type);
    try std.testing.expectEqualStrings("name", stmt.create_table.columns[1].name);
    try std.testing.expectEqual(ast.DataType.varchar, stmt.create_table.columns[1].data_type);
}

test "parse insert" {
    var parser = Parser.init("INSERT INTO users VALUES (42, 'alice', true);", std.testing.allocator);
    const stmt = try parser.parse_statement();
    defer std.testing.allocator.free(stmt.insert.values);
    try std.testing.expect(stmt == .insert);
    try std.testing.expectEqualStrings("users", stmt.insert.table_name);
    try std.testing.expectEqual(@as(usize, 3), stmt.insert.values.len);
    try std.testing.expectEqual(@as(u64, 42), stmt.insert.values[0].int);
    try std.testing.expectEqualStrings("alice", stmt.insert.values[1].varchar);
    try std.testing.expectEqual(true, stmt.insert.values[2].bool);
}

test "parse select eq" {
    var parser = Parser.init("SELECT * FROM users WHERE key = 42;", std.testing.allocator);
    const stmt = try parser.parse_statement();
    try std.testing.expect(stmt == .select);
    try std.testing.expectEqualStrings("users", stmt.select.table_name);
    try std.testing.expect(stmt.select.columns == null);
    try std.testing.expect(stmt.select.condition != null);
    try std.testing.expect(stmt.select.condition.? == .compare);
    try std.testing.expectEqualStrings("key", stmt.select.condition.?.compare.column);
    try std.testing.expect(stmt.select.condition.?.compare.op == .eq);
    try std.testing.expectEqual(@as(u64, 42), stmt.select.condition.?.compare.value.int);
}

test "parse select projection" {
    var parser = Parser.init("SELECT name, id FROM users;", std.testing.allocator);
    const stmt = try parser.parse_statement();
    try std.testing.expect(stmt == .select);
    try std.testing.expectEqualStrings("users", stmt.select.table_name);
    
    try std.testing.expect(stmt.select.columns != null);
    const cols = stmt.select.columns.?;
    defer std.testing.allocator.free(cols);
    
    try std.testing.expectEqual(@as(usize, 2), cols.len);
    try std.testing.expectEqualStrings("name", cols[0]);
    try std.testing.expectEqualStrings("id", cols[1]);
    try std.testing.expect(stmt.select.condition == null);
}

test "parse select join" {
    var parser = Parser.init("SELECT * FROM users JOIN roles ON id = user_id;", std.testing.allocator);
    const stmt = try parser.parse_statement();
    try std.testing.expect(stmt == .select);
    try std.testing.expectEqualStrings("users", stmt.select.table_name);
    try std.testing.expectEqualStrings("roles", stmt.select.join_table.?);
    
    try std.testing.expect(stmt.select.join_condition != null);
    try std.testing.expect(stmt.select.join_condition.? == .column_compare);
    try std.testing.expectEqualStrings("id", stmt.select.join_condition.?.column_compare.left_column);
    try std.testing.expect(stmt.select.join_condition.?.column_compare.op == .eq);
    try std.testing.expectEqualStrings("user_id", stmt.select.join_condition.?.column_compare.right_column);
}

test "parse select range" {
    var parser = Parser.init("SELECT * FROM users WHERE key >= 10 AND key <= 20;", std.testing.allocator);
    const stmt = try parser.parse_statement();
    try std.testing.expect(stmt == .select);
    try std.testing.expectEqualStrings("users", stmt.select.table_name);
    try std.testing.expect(stmt.select.condition != null);
    try std.testing.expect(stmt.select.condition.? == .and_expr);
    const and_expr = stmt.select.condition.?.and_expr;
    defer std.testing.allocator.destroy(and_expr.left);
    defer std.testing.allocator.destroy(and_expr.right);

    const left = and_expr.left.*;
    const right = and_expr.right.*;

    try std.testing.expect(left == .compare and left.compare.op == .gte);
    try std.testing.expectEqualStrings("key", left.compare.column);
    try std.testing.expectEqual(@as(u64, 10), left.compare.value.int);

    try std.testing.expect(right == .compare and right.compare.op == .lte);
    try std.testing.expectEqualStrings("key", right.compare.column);
    try std.testing.expectEqual(@as(u64, 20), right.compare.value.int);
}

test "parse delete" {
    var parser = Parser.init("DELETE FROM users WHERE key = 42;", std.testing.allocator);
    const stmt = try parser.parse_statement();
    try std.testing.expect(stmt == .delete);
    try std.testing.expectEqualStrings("users", stmt.delete.table_name);
    try std.testing.expect(stmt.delete.condition != null);
    try std.testing.expect(stmt.delete.condition.? == .compare);
    try std.testing.expectEqualStrings("key", stmt.delete.condition.?.compare.column);
    try std.testing.expect(stmt.delete.condition.?.compare.op == .eq);
    try std.testing.expectEqual(@as(u64, 42), stmt.delete.condition.?.compare.value.int);
}

test "parse select order limit" {
    var parser = Parser.init("SELECT * FROM users ORDER BY age DESC LIMIT 10 OFFSET 5;", std.testing.allocator);
    const stmt = try parser.parse_statement();
    try std.testing.expect(stmt == .select);
    try std.testing.expectEqualStrings("users", stmt.select.table_name);
    try std.testing.expect(stmt.select.order_by != null);
    try std.testing.expectEqualStrings("age", stmt.select.order_by.?);
    try std.testing.expect(stmt.select.is_desc == true);
    try std.testing.expect(stmt.select.limit != null);
    try std.testing.expectEqual(@as(usize, 10), stmt.select.limit.?);
    try std.testing.expect(stmt.select.offset != null);
    try std.testing.expectEqual(@as(usize, 5), stmt.select.offset.?);
}

test "parse update" {
    var parser = Parser.init("UPDATE users SET is_active = false WHERE id = 42;", std.testing.allocator);
    const stmt = try parser.parse_statement();
    try std.testing.expect(stmt == .update);
    try std.testing.expectEqualStrings("users", stmt.update.table_name);
    try std.testing.expectEqualStrings("is_active", stmt.update.column_name);
    try std.testing.expect(stmt.update.value == .bool);
    try std.testing.expect(stmt.update.value.bool == false);
    try std.testing.expect(stmt.update.condition != null);
    try std.testing.expect(stmt.update.condition.? == .compare);
    try std.testing.expectEqualStrings("id", stmt.update.condition.?.compare.column);
    try std.testing.expect(stmt.update.condition.?.compare.op == .eq);
    try std.testing.expectEqual(@as(u64, 42), stmt.update.condition.?.compare.value.int);
}
