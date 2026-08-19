with open("src/query/parser.zig", "r") as f:
    code = f.read()

code = code.replace(".KeywordUpdate => return self.parse_update(),", ".KeywordUpdate => return self.parse_update(),\n            .KeywordWith => return self.parse_with(),")

parse_with_func = """
    pub fn parse_with(self: *Parser) !ast.Statement {
        self.advance(); // consume WITH
        
        var ctes = std.ArrayList(ast.Cte).init(self.allocator);
        
        while (true) {
            if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
            const cte_name = self.current_token.text;
            self.advance();
            
            if (self.current_token.token_type != .KeywordAs) return error.UnexpectedToken;
            self.advance();
            
            if (self.current_token.token_type != .LeftParen) return error.UnexpectedToken;
            self.advance();
            
            const cte_stmt = try self.parse_statement();
            
            if (self.current_token.token_type != .RightParen) return error.UnexpectedToken;
            self.advance();
            
            const stmt_ptr = try self.allocator.create(ast.Statement);
            stmt_ptr.* = cte_stmt;
            
            try ctes.append(.{
                .name = cte_name,
                .statement = stmt_ptr,
            });
            
            if (self.current_token.token_type == .Comma) {
                self.advance();
            } else {
                break;
            }
        }
        
        const main_stmt = try self.parse_statement();
        const main_ptr = try self.allocator.create(ast.Statement);
        main_ptr.* = main_stmt;
        
        return .{ .with = .{
            .ctes = try ctes.toOwnedSlice(),
            .statement = main_ptr,
        } };
    }

    pub fn parse_expression(self: *Parser) anyerror!ast.Expression {"""

code = code.replace("    pub fn parse_expression(self: *Parser) anyerror!ast.Expression {", parse_with_func)

with open("src/query/parser.zig", "w") as f:
    f.write(code)

