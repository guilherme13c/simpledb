const std = @import("std");
const Parser = @import("../../src/query/parser.zig").Parser;
const ast = @import("../../src/query/ast.zig");

const A = std.testing.allocator;

test "parse: CREATE INDEX with default BTREE" {
    var p = Parser.init("CREATE INDEX idx_age ON users (age);", A);
    const stmt = try p.parse_statement();
    try std.testing.expect(stmt == .create_index);
    try std.testing.expectEqualStrings("idx_age", stmt.create_index.index_name);
    try std.testing.expectEqualStrings("users", stmt.create_index.table_name);
    try std.testing.expectEqualStrings("age", stmt.create_index.column_name);
    try std.testing.expectEqual(ast.IndexType.btree, stmt.create_index.index_type);
}

test "parse: CREATE INDEX USING HASH" {
    var p = Parser.init("CREATE INDEX idx_name ON users (name) USING HASH;", A);
    const stmt = try p.parse_statement();
    try std.testing.expectEqual(ast.IndexType.hash, stmt.create_index.index_type);
}

test "parse: CREATE TABLE with all data types" {
    var p = Parser.init(
        "CREATE TABLE t (a INT, b VARCHAR, c BOOL, d FLOAT, e TIMESTAMP, f JSON, g UUID, h SIGNED_INT);",
        A,
    );
    const stmt = try p.parse_statement();
    defer A.free(stmt.create_table.columns);
    try std.testing.expectEqual(@as(usize, 8), stmt.create_table.columns.len);
    try std.testing.expectEqual(ast.DataType.int, stmt.create_table.columns[0].data_type);
    try std.testing.expectEqual(ast.DataType.varchar, stmt.create_table.columns[1].data_type);
    try std.testing.expectEqual(ast.DataType.bool, stmt.create_table.columns[2].data_type);
    try std.testing.expectEqual(ast.DataType.float, stmt.create_table.columns[3].data_type);
    try std.testing.expectEqual(ast.DataType.timestamp, stmt.create_table.columns[4].data_type);
    try std.testing.expectEqual(ast.DataType.json, stmt.create_table.columns[5].data_type);
    try std.testing.expectEqual(ast.DataType.uuid, stmt.create_table.columns[6].data_type);
    try std.testing.expectEqual(ast.DataType.signed_int, stmt.create_table.columns[7].data_type);
}

test "parse: DROP TABLE" {
    var p = Parser.init("DROP TABLE old_tbl;", A);
    const stmt = try p.parse_statement();
    try std.testing.expect(stmt == .drop_table);
    try std.testing.expectEqualStrings("old_tbl", stmt.drop_table.table_name);
}

test "parse: ALTER TABLE ADD COLUMN" {
    var p = Parser.init("ALTER TABLE users ADD COLUMN email VARCHAR;", A);
    const stmt = try p.parse_statement();
    try std.testing.expect(stmt == .alter_table);
    try std.testing.expectEqualStrings("users", stmt.alter_table.table_name);
    try std.testing.expect(stmt.alter_table.action == .add_column);
    try std.testing.expectEqualStrings("email", stmt.alter_table.action.add_column.name);
    try std.testing.expectEqual(ast.DataType.varchar, stmt.alter_table.action.add_column.data_type);
}

test "parse: ALTER TABLE DROP COLUMN" {
    var p = Parser.init("ALTER TABLE users DROP COLUMN email;", A);
    const stmt = try p.parse_statement();
    try std.testing.expect(stmt == .alter_table);
    try std.testing.expect(stmt.alter_table.action == .drop_column);
    try std.testing.expectEqualStrings("email", stmt.alter_table.action.drop_column);
}

test "parse: ALTER TABLE RENAME COLUMN" {
    var p = Parser.init("ALTER TABLE users RENAME COLUMN old_name TO new_name;", A);
    const stmt = try p.parse_statement();
    try std.testing.expect(stmt == .alter_table);
    try std.testing.expect(stmt.alter_table.action == .rename_column);
    try std.testing.expectEqualStrings("old_name", stmt.alter_table.action.rename_column.old_name);
    try std.testing.expectEqualStrings("new_name", stmt.alter_table.action.rename_column.new_name);
}

test "parse: BEGIN / COMMIT / ROLLBACK / PREPARE" {
    inline for (.{ "BEGIN", "COMMIT", "ROLLBACK", "PREPARE" }) |kw| {
        var p = Parser.init(kw ++ ";", A);
        const stmt = try p.parse_statement();
        _ = stmt;
    }
}

test "parse: EXPLAIN wraps inner statement" {
    var p = Parser.init("EXPLAIN SELECT * FROM users;", A);
    const stmt = try p.parse_statement();
    defer A.destroy(stmt.explain);
    try std.testing.expect(stmt == .explain);
    try std.testing.expect(stmt.explain.* == .select);
    try std.testing.expectEqualStrings("users", stmt.explain.select.table_name);
}

test "parse: SELECT with COUNT(*) aggregate" {
    var p = Parser.init("SELECT COUNT(*) FROM users;", A);
    const stmt = try p.parse_statement();
    defer A.free(stmt.select.aggregates.?);
    try std.testing.expect(stmt == .select);
    try std.testing.expect(stmt.select.aggregates != null);
    try std.testing.expectEqual(@as(usize, 1), stmt.select.aggregates.?.len);
    try std.testing.expectEqual(ast.AggregateOp.count, stmt.select.aggregates.?[0].op);
    try std.testing.expect(stmt.select.aggregates.?[0].column == null);
}

test "parse: SELECT with SUM(col) GROUP BY" {
    var p = Parser.init("SELECT SUM(price) FROM orders GROUP BY category;", A);
    const stmt = try p.parse_statement();
    defer A.free(stmt.select.aggregates.?);
    try std.testing.expectEqual(ast.AggregateOp.sum, stmt.select.aggregates.?[0].op);
    try std.testing.expectEqualStrings("price", stmt.select.aggregates.?[0].column.?);
    try std.testing.expectEqualStrings("category", stmt.select.group_by.?);
}

test "parse: SELECT with window ROW_NUMBER OVER (PARTITION BY ... ORDER BY ...)" {
    var p = Parser.init(
        "SELECT ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) FROM employees;",
        A,
    );
    const stmt = try p.parse_statement();
    defer A.free(stmt.select.window_functions.?);
    try std.testing.expect(stmt.select.window_functions != null);
    const win = stmt.select.window_functions.?[0];
    try std.testing.expectEqual(ast.WindowFuncType.row_number, win.func);
    try std.testing.expectEqualStrings("dept", win.partition_by.?);
    try std.testing.expectEqualStrings("salary", win.order_by.?);
    try std.testing.expect(win.is_desc);
}

test "parse: SELECT with RANK OVER (...)" {
    var p = Parser.init("SELECT RANK() OVER (ORDER BY score) FROM leaderboard;", A);
    const stmt = try p.parse_statement();
    defer A.free(stmt.select.window_functions.?);
    const win = stmt.select.window_functions.?[0];
    try std.testing.expectEqual(ast.WindowFuncType.rank, win.func);
    try std.testing.expectEqualStrings("score", win.order_by.?);
    try std.testing.expect(!win.is_desc);
}

test "parse: LEFT OUTER JOIN / RIGHT OUTER JOIN / FULL OUTER JOIN" {
    const cases = [_]struct { sql: []const u8, jt: ast.JoinType }{
        .{ .sql = "SELECT * FROM a LEFT OUTER JOIN b ON a.id = b.aid;", .jt = .left },
        .{ .sql = "SELECT * FROM a RIGHT OUTER JOIN b ON a.id = b.aid;", .jt = .right },
        .{ .sql = "SELECT * FROM a FULL OUTER JOIN b ON a.id = b.aid;", .jt = .full },
        .{ .sql = "SELECT * FROM a LEFT JOIN b ON a.id = b.aid;", .jt = .left },
        .{ .sql = "SELECT * FROM a RIGHT JOIN b ON a.id = b.aid;", .jt = .right },
        .{ .sql = "SELECT * FROM a FULL JOIN b ON a.id = b.aid;", .jt = .full },
    };
    for (cases) |c| {
        var p = Parser.init(c.sql, A);
        const stmt = try p.parse_statement();
        defer {
            if (stmt.select.join_condition) |jc| {
                if (jc == .column_compare) {} // no alloc for column_compare
            }
        }
        try std.testing.expectEqual(c.jt, stmt.select.join_type);
        try std.testing.expectEqualStrings("b", stmt.select.join_table.?);
    }
}

test "parse: multi-column ORDER BY" {
    var p = Parser.init("SELECT * FROM t ORDER BY a ASC, b DESC;", A);
    const stmt = try p.parse_statement();
    defer A.free(stmt.select.order_by.?);
    try std.testing.expectEqual(@as(usize, 2), stmt.select.order_by.?.len);
    try std.testing.expectEqualStrings("a", stmt.select.order_by.?[0].column);
    try std.testing.expect(!stmt.select.order_by.?[0].is_desc);
    try std.testing.expectEqualStrings("b", stmt.select.order_by.?[1].column);
    try std.testing.expect(stmt.select.order_by.?[1].is_desc);
}

test "parse: scalar subquery in WHERE" {
    var p = Parser.init("SELECT * FROM a WHERE id = (SELECT id FROM b);", A);
    const stmt = try p.parse_statement();
    defer {
        const sub = stmt.select.condition.?.compare_subquery.subquery;
        if (sub.select.columns) |cols| A.free(cols);
        A.destroy(sub);
    }
    try std.testing.expect(stmt.select.condition.? == .compare_subquery);
    try std.testing.expectEqualStrings("id", stmt.select.condition.?.compare_subquery.column);
    try std.testing.expect(stmt.select.condition.?.compare_subquery.subquery.* == .select);
}

test "parse: WITH (single CTE)" {
    var p = Parser.init("WITH cte1 AS (SELECT * FROM a) SELECT * FROM cte1;", A);
    const stmt = try p.parse_statement();
    defer {
        for (stmt.with.ctes) |cte| {
            A.destroy(cte.statement);
        }
        A.free(stmt.with.ctes);
        A.destroy(stmt.with.statement);
    }
    try std.testing.expect(stmt == .with);
    try std.testing.expectEqual(@as(usize, 1), stmt.with.ctes.len);
    try std.testing.expectEqualStrings("cte1", stmt.with.ctes[0].name);
    try std.testing.expect(stmt.with.ctes[0].statement.* == .select);
    try std.testing.expect(stmt.with.statement.* == .select);
}

test "parse: error on empty input" {
    var p = Parser.init("", A);
    try std.testing.expectError(error.UnexpectedToken, p.parse_statement());
}

test "parse: error on malformed CREATE (missing type)" {
    var p = Parser.init("CREATE TABLE t (a NOTATYPE);", A);
    try std.testing.expectError(error.UnexpectedToken, p.parse_statement());
}

test "parse: error on malformed INSERT (missing RParen)" {
    var p = Parser.init("INSERT INTO t VALUES (1, 'x';", A);
    try std.testing.expectError(error.UnexpectedToken, p.parse_statement());
}

test "parse: error on ROW_NUMBER without OVER" {
    var p = Parser.init("SELECT ROW_NUMBER() FROM t;", A);
    try std.testing.expectError(error.UnexpectedToken, p.parse_statement());
}

test "parse: error on CREATE INDEX on non-existent-grammar" {
    var p = Parser.init("CREATE INDEX idx ON tbl (col) USING INVALID;", A);
    try std.testing.expectError(error.UnexpectedToken, p.parse_statement());
}

test "parse: INSERT with float and bool values" {
    var p = Parser.init("INSERT INTO t VALUES (3.14, true, false, 'str', 42);", A);
    const stmt = try p.parse_statement();
    defer A.free(stmt.insert.values);
    try std.testing.expectEqual(@as(usize, 5), stmt.insert.values.len);
    try std.testing.expect(stmt.insert.values[0] == .float);
    try std.testing.expect(stmt.insert.values[1] == .bool and stmt.insert.values[1].bool);
    try std.testing.expect(stmt.insert.values[2] == .bool and !stmt.insert.values[2].bool);
    try std.testing.expectEqualStrings("str", stmt.insert.values[3].varchar);
    try std.testing.expectEqual(@as(u64, 42), stmt.insert.values[4].int);
}
