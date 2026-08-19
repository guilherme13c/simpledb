import re

with open("src/query/parser.zig", "r") as f:
    code = f.read()

# We want to replace everything from "while (true) {" to "if (agg_list.items.len > 0) aggregates = try agg_list.toOwnedSlice(self.allocator);"
start_idx = code.find("            while (true) {")
end_str = "            if (agg_list.items.len > 0) aggregates = try agg_list.toOwnedSlice(self.allocator);"
end_idx = code.find(end_str, start_idx) + len(end_str)

replacement = """
            var win_list = std.ArrayList(ast.WindowFunctionExpr).empty;
            errdefer win_list.deinit(self.allocator);

            while (true) {
                var is_agg = false;
                var is_win = false;
                var agg_op: ast.AggregateOp = .count;
                var win_op: ast.WindowFuncType = .row_number;
                
                if (self.current_token.token_type == .KeywordCount) { is_agg = true; agg_op = .count; win_op = .count; }
                else if (self.current_token.token_type == .KeywordSum) { is_agg = true; agg_op = .sum; win_op = .sum; }
                else if (self.current_token.token_type == .KeywordMin) { is_agg = true; agg_op = .min; }
                else if (self.current_token.token_type == .KeywordMax) { is_agg = true; agg_op = .max; }
                else if (self.current_token.token_type == .KeywordAvg) { is_agg = true; agg_op = .avg; }
                else if (self.current_token.token_type == .KeywordRowNumber) { is_win = true; win_op = .row_number; }
                else if (self.current_token.token_type == .KeywordRank) { is_win = true; win_op = .rank; }
                
                if (is_agg or is_win) {
                    self.advance(); // consume kw
                    try self.match(.LParen);
                    
                    var col_name: ?[]const u8 = null;
                    if (self.current_token.token_type == .Asterisk) {
                        self.advance();
                    } else if (self.current_token.token_type == .Identifier) {
                        col_name = self.current_token.text;
                        self.advance();
                    } else if (self.current_token.token_type != .RParen) { 
                        return error.UnexpectedToken;
                    }
                    try self.match(.RParen);
                    
                    // Check if OVER follows
                    if (self.current_token.token_type == .KeywordOver) {
                        self.advance();
                        try self.match(.LParen);
                        
                        var partition_by: ?[]const u8 = null;
                        var order_by: ?[]const u8 = null;
                        var is_desc = false;
                        
                        if (self.current_token.token_type == .KeywordPartition) {
                            self.advance();
                            try self.match(.KeywordBy);
                            if (self.current_token.token_type != .Identifier) return error.UnexpectedToken;
                            partition_by = self.current_token.text;
                            self.advance();
                        }
                        
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
                        
                        try self.match(.RParen);
                        
                        try win_list.append(self.allocator, .{
                            .func = win_op,
                            .arg_column = col_name,
                            .partition_by = partition_by,
                            .order_by = order_by,
                            .is_desc = is_desc,
                        });
                        
                    } else {
                        if (is_win) return error.UnexpectedToken; // ROW_NUMBER needs OVER
                        try agg_list.append(self.allocator, .{ .op = agg_op, .column = col_name });
                    }
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
            
"""
code = code[:start_idx] + replacement + code[end_idx:]

code = code.replace("var window_functions: ?[]const ast.WindowFunctionExpr = null;", "") # cleanup if exists

code = code.replace("var aggregates: ?[]const ast.AggregateExpr = null;", "var aggregates: ?[]const ast.AggregateExpr = null;\n        var window_functions: ?[]const ast.WindowFunctionExpr = null;")

code = code.replace("if (agg_list.items.len > 0) aggregates = try agg_list.toOwnedSlice(self.allocator);\n", "if (agg_list.items.len > 0) aggregates = try agg_list.toOwnedSlice(self.allocator);\n            if (win_list.items.len > 0) window_functions = try win_list.toOwnedSlice(self.allocator);\n")


code = code.replace(".window_functions = null, .table_name", ".window_functions = window_functions, .table_name")

with open("src/query/parser.zig", "w") as f:
    f.write(code)

