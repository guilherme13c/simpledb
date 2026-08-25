const std = @import("std");
const ast = @import("../../src/query/ast.zig");
const exec = @import("../../src/query/executor.zig");
const InMemoryTable = @import("../../src/storage/in_memory_table.zig").InMemoryTable;
const InMemoryScanExecutor = exec.InMemoryScanExecutor;
const FilterExecutor = exec.FilterExecutor;
const ProjectExecutor = exec.ProjectExecutor;
const LimitExecutor = exec.LimitExecutor;
const OrderByExecutor = exec.OrderByExecutor;
const AggregateExecutor = exec.AggregateExecutor;
const InMemoryInsertExecutor = exec.InMemoryInsertExecutor;
const Executor = exec.Executor;
const free_tuple = exec.free_tuple;

const A = std.testing.allocator;

const Schema = struct {
    cols: []const ast.ColumnDef,
};

fn schema(cols: []const ast.ColumnDef) []const ast.ColumnDef {
    return cols;
}

const person_schema = [_]ast.ColumnDef{
    .{ .name = "id", .data_type = .int },
    .{ .name = "age", .data_type = .int },
    .{ .name = "name", .data_type = .varchar },
};

fn makePeopleTable() !InMemoryTable {
    var t = try InMemoryTable.init(A, &person_schema);
    try t.insert_tuple(&[_]ast.Value{ .{ .int = 1 }, .{ .int = 30 }, .{ .varchar = "alice" } });
    try t.insert_tuple(&[_]ast.Value{ .{ .int = 2 }, .{ .int = 20 }, .{ .varchar = "bob" } });
    try t.insert_tuple(&[_]ast.Value{ .{ .int = 3 }, .{ .int = 40 }, .{ .varchar = "carol" } });
    try t.insert_tuple(&[_]ast.Value{ .{ .int = 4 }, .{ .int = 25 }, .{ .varchar = "dave" } });
    return t;
}

fn collectAll(e: *Executor, out: *std.ArrayList([]ast.Value)) !void {
    while (try e.next()) |tuple| {
        try out.append(A, tuple);
    }
}

test "InMemoryScanExecutor: yields all rows in order" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var e = Executor{ .in_memory_scan = &scan };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    try std.testing.expectEqual(@as(u64, 1), rows.items[0][0].int);
    try std.testing.expectEqualStrings("alice", rows.items[0][2].varchar);
}

test "FilterExecutor: age >= 30" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var filter = FilterExecutor{
        .child = .{ .in_memory_scan = &scan },
        .expression = .{ .compare = .{ .column = "age", .op = .gte, .value = .{ .int = 30 } } },
        .schema = &person_schema,
        .allocator = A,
    };
    var e = Executor{ .filter = &filter };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    // alice (30) and carol (40)
    try std.testing.expectEqualStrings("alice", rows.items[0][2].varchar);
    try std.testing.expectEqualStrings("carol", rows.items[1][2].varchar);
}

test "FilterExecutor: AND expression age >= 20 AND age <= 30" {
    var t = try makePeopleTable();
    defer t.deinit();

    const left = try A.create(ast.Expression);
    left.* = .{ .compare = .{ .column = "age", .op = .gte, .value = .{ .int = 20 } } };
    const right = try A.create(ast.Expression);
    right.* = .{ .compare = .{ .column = "age", .op = .lte, .value = .{ .int = 30 } } };
    defer {
        A.destroy(left);
        A.destroy(right);
    }

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var filter = FilterExecutor{
        .child = .{ .in_memory_scan = &scan },
        .expression = .{ .and_expr = .{ .left = left, .right = right } },
        .schema = &person_schema,
        .allocator = A,
    };
    var e = Executor{ .filter = &filter };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len); // alice(30), bob(20), dave(25)
}

test "ProjectExecutor: select id, name only" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var column_indices_02 = [_]usize{ 0, 2 };
    var project = ProjectExecutor{
        .child = .{ .in_memory_scan = &scan },
        .column_indices = column_indices_02[0..],
        .allocator = A,
    };
    var e = Executor{ .project = &project };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    for (rows.items) |r| {
        try std.testing.expectEqual(@as(usize, 2), r.len); // only 2 projected columns
    }
    try std.testing.expectEqual(@as(u64, 1), rows.items[0][0].int);
    try std.testing.expectEqualStrings("alice", rows.items[0][1].varchar);
}

test "LimitExecutor: limit 2 offset 1" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var scan_child = Executor{ .in_memory_scan = &scan };
    var limit = LimitExecutor{
        .child = &scan_child,
        .limit = 2,
        .offset = 1,
        .allocator = A,
    };
    var e = Executor{ .limit = &limit };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    // offset 1 skips id=1; yields id=2 (bob), id=3 (carol)
    try std.testing.expectEqual(@as(u64, 2), rows.items[0][0].int);
    try std.testing.expectEqual(@as(u64, 3), rows.items[1][0].int);
}

test "LimitExecutor: limit larger than available rows" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var scan_child = Executor{ .in_memory_scan = &scan };
    var limit = LimitExecutor{
        .child = &scan_child,
        .limit = 100,
        .offset = null,
        .allocator = A,
    };
    var e = Executor{ .limit = &limit };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
}

test "OrderByExecutor: sort by age ASC" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var scan_child = Executor{ .in_memory_scan = &scan };
    var order = OrderByExecutor{
        .child = &scan_child,
        .order_by_exprs = &[_]ast.OrderByExpr{.{ .column = "age", .is_desc = false }},
        .schema = &person_schema,
        .allocator = A,
    };
    var e = Executor{ .order_by = &order };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    // ascending ages: 20, 25, 30, 40 → bob, dave, alice, carol
    try std.testing.expectEqual(@as(u64, 20), rows.items[0][1].int);
    try std.testing.expectEqual(@as(u64, 25), rows.items[1][1].int);
    try std.testing.expectEqual(@as(u64, 30), rows.items[2][1].int);
    try std.testing.expectEqual(@as(u64, 40), rows.items[3][1].int);
}

test "OrderByExecutor: sort by age DESC" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var scan_child = Executor{ .in_memory_scan = &scan };
    var order = OrderByExecutor{
        .child = &scan_child,
        .order_by_exprs = &[_]ast.OrderByExpr{.{ .column = "age", .is_desc = true }},
        .schema = &person_schema,
        .allocator = A,
    };
    var e = Executor{ .order_by = &order };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    // descending: 40, 30, 25, 20
    try std.testing.expectEqual(@as(u64, 40), rows.items[0][1].int);
    try std.testing.expectEqual(@as(u64, 20), rows.items[3][1].int);
}

test "AggregateExecutor: COUNT(*) global" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var agg = AggregateExecutor{
        .child = .{ .in_memory_scan = &scan },
        .group_by_col_idx = null,
        .agg_op = .count,
        .agg_col_idx = null,
        .allocator = A,
    };
    var e = Executor{ .aggregate = &agg };
    try e.open();
    defer e.close();

    const result = (try e.next()).?;
    defer free_tuple(A, result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u64, 4), result[0].int);

    try std.testing.expect(try e.next() == null); // only one global row
}

test "AggregateExecutor: SUM(age) GROUP BY no grouping (global sum)" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var agg = AggregateExecutor{
        .child = .{ .in_memory_scan = &scan },
        .group_by_col_idx = null,
        .agg_op = .sum,
        .agg_col_idx = 1,
        .allocator = A,
    };
    var e = Executor{ .aggregate = &agg };
    try e.open();
    defer e.close();

    const result = (try e.next()).?;
    defer free_tuple(A, result);
    // 30 + 20 + 40 + 25 = 115
    try std.testing.expectEqual(@as(u64, 115), result[0].int);
}

test "InMemoryInsertExecutor: inserts child rows and returns count" {
    var src = try makePeopleTable();
    defer src.deinit();
    var dst = try InMemoryTable.init(A, &person_schema);
    defer dst.deinit();

    var scan = InMemoryScanExecutor{ .table = &src, .allocator = A };
    var scan_child = Executor{ .in_memory_scan = &scan };
    var ins = InMemoryInsertExecutor{
        .table = &dst,
        .child = &scan_child,
        .allocator = A,
    };
    var e = Executor{ .in_memory_insert = &ins };
    try e.open();
    defer e.close();

    const result = (try e.next()).?;
    defer free_tuple(A, result);
    try std.testing.expectEqual(@as(u64, 4), result[0].int);
    try std.testing.expect(try e.next() == null);

    // dst now has 4 rows
    try std.testing.expectEqual(@as(usize, 4), dst.tuples.items.len);
}

test "Pipeline: scan -> filter -> project -> limit (composite)" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var filter = FilterExecutor{
        .child = .{ .in_memory_scan = &scan },
        .expression = .{ .compare = .{ .column = "age", .op = .gte, .value = .{ .int = 25 } } },
        .schema = &person_schema,
        .allocator = A,
    };
    var col_idx_name = [_]usize{2};
    var project = ProjectExecutor{
        .child = .{ .filter = &filter },
        .column_indices = col_idx_name[0..],
        .allocator = A,
    };
    var project_child = Executor{ .project = &project };
    var limit = LimitExecutor{
        .child = &project_child,
        .limit = 2,
        .offset = null,
        .allocator = A,
    };
    var e = Executor{ .limit = &limit };
    try e.open();
    defer e.close();

    var rows = std.ArrayList([]ast.Value).empty;
    defer {
        for (rows.items) |r| free_tuple(A, r);
        rows.deinit(A);
    }
    try collectAll(&e, &rows);
    // age >= 25 → alice(30), carol(40), dave(25); limit 2 → alice, carol
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("alice", rows.items[0][0].varchar);
    try std.testing.expectEqualStrings("carol", rows.items[1][0].varchar);
}

test "Executor.explain: prints plan tree" {
    var t = try makePeopleTable();
    defer t.deinit();

    var scan = InMemoryScanExecutor{ .table = &t, .allocator = A };
    var filter = FilterExecutor{
        .child = .{ .in_memory_scan = &scan },
        .expression = .{ .compare = .{ .column = "age", .op = .eq, .value = .{ .int = 30 } } },
        .schema = &person_schema,
        .allocator = A,
    };
    var e = Executor{ .filter = &filter };
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try e.explain(&fbs, 0);
    const written = std.Io.Writer.buffered(&fbs);

    try std.testing.expect(std.mem.indexOf(u8, written, "Filter") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "InMemoryScan") != null);
}
