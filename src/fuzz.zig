const std = @import("std");
const Lexer = @import("query/lexer.zig").Lexer;
const Parser = @import("query/parser.zig").Parser;

pub fn main() !void {
    std.debug.print("Entering main...\n", .{});
    const allocator = std.heap.page_allocator;

    const input_buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(input_buf);

    const bytes_read = std.posix.read(0, input_buf) catch |err| {
        std.debug.print("Read error: {}\n", .{err});
        return;
    };
    const input = input_buf[0..bytes_read];

    // Fuzz the Lexer
    var lexer = Lexer.init(input);
    while (true) {
        const token = lexer.next_token();
        if (token.token_type == .EOF or token.token_type == .Error) break;
    }

    // Fuzz the Parser
    var parser = Parser.init(input, allocator);
    // Ignore errors from the parser, we just want to ensure it doesn't crash or leak memory.
    const stmt = parser.parse_statement() catch return;

    // If it successfully parsed, make sure to free allocations if it's a create table or insert
    switch (stmt) {
        .create_table => {
            allocator.free(stmt.create_table.columns);
        },
        .insert => {
            allocator.free(stmt.insert.values);
        },
        else => {},
    }

    std.debug.print("Successfully parsed.\n", .{});
}
