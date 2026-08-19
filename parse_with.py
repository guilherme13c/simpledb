import re

with open("src/query/lexer.zig", "r") as f:
    content = f.read()

content = content.replace('KeywordExplain,', 'KeywordExplain,\n    KeywordWith,\n    KeywordAs,')
content = content.replace('else if (std.mem.eql(u8, upper_text, "EXPLAIN")) .KeywordExplain', 'else if (std.mem.eql(u8, upper_text, "EXPLAIN")) .KeywordExplain\n        else if (std.mem.eql(u8, upper_text, "WITH")) .KeywordWith\n        else if (std.mem.eql(u8, upper_text, "AS")) .KeywordAs')

with open("src/query/lexer.zig", "w") as f:
    f.write(content)

with open("src/query/parser.zig", "r") as f:
    content = f.read()

parse_statement = """    pub fn parse_statement(self: *Parser) anyerror!ast.Statement {
        if (self.current_token.token_type == .KeywordExplain) {
            self.advance();
            const inner_stmt = try self.allocator.create(ast.Statement);
            inner_stmt.* = try self.parse_statement();
            return .{ .explain = inner_stmt };
        }
        
        if (self.current_token.token_type == .KeywordWith) {
            self.advance();
            var ctes = std.ArrayList(ast.Cte).init(self.allocator);
            while (true) {
                if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
                const cte_name = self.current_token.text;
                self.advance();
                
                try self.match(.KeywordAs);
                try self.match(.LParen);
                
                const cte_stmt = try self.allocator.create(ast.Statement);
                cte_stmt.* = try self.parse_select();
                
                try self.match(.RParen);
                
                try ctes.append(.{ .name = cte_name, .statement = cte_stmt });
                
                if (self.current_token.token_type == .Comma) {
                    self.advance();
                } else {
                    break;
                }
            }
            
            const main_stmt = try self.allocator.create(ast.Statement);
            main_stmt.* = try self.parse_statement();
            
            return .{ .with = .{ .ctes = try ctes.toOwnedSlice(), .statement = main_stmt } };
        }
"""
content = content.replace("""    pub fn parse_statement(self: *Parser) anyerror!ast.Statement {
        if (self.current_token.token_type == .KeywordExplain) {
            self.advance();
            const inner_stmt = try self.allocator.create(ast.Statement);
            inner_stmt.* = try self.parse_statement();
            return .{ .explain = inner_stmt };
        }""", parse_statement)

with open("src/query/parser.zig", "w") as f:
    f.write(content)
