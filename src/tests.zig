const std = @import("std");

// Import all files to ensure their internal tests are run
comptime {
    _ = @import("storage/page/page.zig");
    _ = @import("storage/page/slotted_view.zig");
    _ = @import("storage/storage_manager/storage_manager.zig");
    _ = @import("storage/buffer_manager/buffer_manager.zig");
    _ = @import("storage/index/btree.zig");
    _ = @import("query/lexer.zig");
    _ = @import("query/parser.zig");
    _ = @import("query/executor.zig");
    _ = @import("storage/index/btree_node.zig");
    _ = @import("storage/wal/log_manager.zig");
    _ = @import("storage/wal/recovery_manager.zig");
}

const sm = @import("storage/storage_manager/storage_manager.zig");
const bm = @import("storage/buffer_manager/buffer_manager.zig");
const BTree = @import("storage/index/btree.zig").BTree;
const Table = @import("storage/table.zig").Table;
const Catalog = @import("storage/catalog.zig").Catalog;
const LogManager = @import("storage/wal/log_manager.zig").LogManager;
const RecoveryManager = @import("storage/wal/recovery_manager.zig").RecoveryManager;

test "BTree insertion and scan" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "data/test_btree.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    
    var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;

    // Allocate root for BTree
    const root_page_id = next_page_counter;
    next_page_counter += 1;
    {
        const root_frame = try buffer_mgr.new_frame(root_page_id);
        _ = @import("storage/index/btree_node.zig").BTreeNodeView.init(&root_frame.page, .leaf);
        buffer_mgr.unpin_frame(root_frame, true);
    }

    var btree = try BTree.init(&buffer_mgr, root_page_id, &next_page_counter);
    
    // Insert heavily to trigger splits
    var i: u64 = 0;
    while (i < 2000) : (i += 1) {
        try btree.insert(null, i, i * 10);
    }

    // Search for a specific key
    const val = try btree.search(1500);
    try std.testing.expectEqual(@as(u64, 15000), val.?);

    // Scan range
    const rids = try btree.scan(std.testing.allocator, 1000, 1010);
    defer std.testing.allocator.free(rids);
    try std.testing.expectEqual(@as(usize, 11), rids.len);
    try std.testing.expectEqual(@as(u64, 10000), rids[0]);
    try std.testing.expectEqual(@as(u64, 10100), rids[10]);

    try btree.delete(null, 1005);
    const rids_after = try btree.scan(std.testing.allocator, 1000, 1010);
    defer std.testing.allocator.free(rids_after);
    try std.testing.expectEqual(@as(usize, 10), rids_after.len);
    try std.testing.expectEqual(@as(u64, 10000), rids_after[0]);
    try std.testing.expectEqual(@as(u64, 10100), rids_after[9]);
}



test "Catalog and Table end-to-end" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "data/test_catalog.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    
    var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;

    var catalog = try Catalog.init(std.testing.allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();
    
    try catalog.create_table("users", &[_]@import("query/ast.zig").ColumnDef{});
    
    const table = catalog.get_table("users").?;
    _ = try table.insert(null, 1, "alice");
    _ = try table.insert(null, 2, "bob");
    
    const alice = try table.search(std.testing.allocator, null, 1);
    defer std.testing.allocator.free(alice.?);
    try std.testing.expectEqualStrings("alice", alice.?);
    
    const not_found = try table.search(std.testing.allocator, null, 99);
    try std.testing.expectEqual(@as(?[]u8, null), not_found);
    
    try catalog.drop_table("users");
    try std.testing.expectEqual(@as(?*Table, null), catalog.get_table("users"));
}

test "Schema Serialization and Deserialization" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "data/test_schema.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    
    // Step 1: Create DB, initialize catalog, and create a table with a schema
    {
        var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
        defer storage_mgr.deinit();

        var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
        defer buffer_mgr.deinit();

        var next_page_counter: u32 = 1;

        var catalog = try Catalog.init(std.testing.allocator, &buffer_mgr, &next_page_counter);
        defer catalog.deinit();
        
        const schema = [_]@import("query/ast.zig").ColumnDef{
            .{ .name = "id", .data_type = .int },
            .{ .name = "name", .data_type = .varchar },
            .{ .name = "is_active", .data_type = .bool },
        };
        
        try catalog.create_table("employees", &schema);
    }

    // Step 2: Restart the DB. The buffer pool will be flushed and re-read from disk.
    {
        var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
        defer storage_mgr.deinit();

        var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
        defer buffer_mgr.deinit();

        var next_page_counter: u32 = 1;

        // This will load sys_tables from disk
        var catalog = try Catalog.init(std.testing.allocator, &buffer_mgr, &next_page_counter);
        defer catalog.deinit();

        const table = catalog.get_table("employees").?;
        try std.testing.expectEqual(@as(usize, 3), table.schema.len);
        
        try std.testing.expectEqualStrings("id", table.schema[0].name);
        try std.testing.expectEqual(@import("query/ast.zig").DataType.int, table.schema[0].data_type);
        
        try std.testing.expectEqualStrings("name", table.schema[1].name);
        try std.testing.expectEqual(@import("query/ast.zig").DataType.varchar, table.schema[1].data_type);
        
        try std.testing.expectEqualStrings("is_active", table.schema[2].name);
        try std.testing.expectEqual(@import("query/ast.zig").DataType.bool, table.schema[2].data_type);
    }
}

test "LogManager and RecoveryManager physical logging" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_wal = "data/test_recovery.wal";
    const test_db = "data/test_recovery.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, test_wal) catch {};
    
    // Step 1: Create a DB, write some logs, and crash
    {
        var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
        defer storage_mgr.deinit();

        const dir = std.Io.Dir.cwd();
        const wal_file = try std.Io.Dir.createFile(dir, io, test_wal, .{ .read = true, .truncate = true });
        var log_mgr = try LogManager.init(io, wal_file);

        var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
        buffer_mgr.log_manager = &log_mgr;
        defer buffer_mgr.deinit();

        var next_page_counter: u32 = 1;
        var catalog = try Catalog.init(std.testing.allocator, &buffer_mgr, &next_page_counter);
        defer catalog.deinit();

        try catalog.create_table("users", &[_]@import("query/ast.zig").ColumnDef{});
        const table = catalog.get_table("users").?;

        var txn_ctx = @import("storage/wal/transaction.zig").TransactionContext{ .txn_id = 1 };
        txn_ctx.prev_lsn = try log_mgr.append_record(txn_ctx.txn_id, 0, .begin, 0, 0, &[_]u8{});
        
        _ = try table.insert(&txn_ctx, 1, "alice");
        try log_mgr.flush(txn_ctx.prev_lsn);
    }
    
    // Step 2: Recover
    {
        var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
        defer storage_mgr.deinit();

        const dir = std.Io.Dir.cwd();
        const wal_file = try std.Io.Dir.openFile(dir, io, test_wal, .{ .mode = .read_write });
        defer wal_file.close(io);

        var log_mgr = try LogManager.init(io, wal_file);

        var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
        buffer_mgr.log_manager = &log_mgr;
        defer buffer_mgr.deinit();

        var recovery_mgr = RecoveryManager.init(io, std.testing.allocator, &log_mgr, &buffer_mgr);
        defer recovery_mgr.deinit();
        
        try recovery_mgr.recover();
        
        // Assert transaction 1 is in ATT and needs undo (since it didn't commit)
        try std.testing.expect(recovery_mgr.att.contains(1));
    }
}

test "Server execution logic" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "data/test_server_exec.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    
    var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;
    var catalog = try Catalog.init(std.testing.allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();
    
    const Server = @import("server/server.zig").Server;
    var server = try Server.init(std.testing.allocator, io, 8080, &catalog, null);
    
    // CREATE TABLE
    const schema = [_]@import("query/ast.zig").ColumnDef{
        .{ .name = "id", .data_type = .int },
        .{ .name = "name", .data_type = .varchar },
    };
    try server.execute_statement(.{ .create_table = .{ .table_name = "test_table", .columns = &schema } }, null, null, null);
    try std.testing.expect(catalog.get_table("test_table") != null);
    
    // INSERT
    try server.execute_statement(.{ .insert = .{ .table_name = "test_table", .values = &[_]@import("query/ast.zig").Value{ .{ .int = 1 }, .{ .varchar = "val1" } } } }, null, null, null);
    
    // SEARCH
    const table = catalog.get_table("test_table").?;
    const res = try table.search(std.testing.allocator, null, 1);
    defer std.testing.allocator.free(res.?);
    
    // Deserialize and check
    const decoded_values = try table.deserialize_tuple(std.testing.allocator, res.?);
    defer {
        for (decoded_values) |v| if (v == .varchar) std.testing.allocator.free(v.varchar);
        std.testing.allocator.free(decoded_values);
    }
    
    try std.testing.expectEqual(@as(usize, 2), decoded_values.len);
    try std.testing.expectEqual(@as(u64, 1), decoded_values[0].int);
    try std.testing.expectEqualStrings("val1", decoded_values[1].varchar);
    
    // DELETE
    try server.execute_statement(.{ .delete = .{ .table_name = "test_table", .condition = .{ .compare = .{ .column = "id", .op = .eq, .value = .{ .int = 1 } } } } }, null, null, null);
    
    const res2 = try table.search(std.testing.allocator, null, 1);
    try std.testing.expectEqual(@as(?[]u8, null), res2);
}

test "Volcano Executor: SeqScan, IndexScan, Filter" {
    const exec = @import("query/executor.zig");
    const ast_mod = @import("query/ast.zig");

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "data/test_volcano.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;
    var catalog = try Catalog.init(std.testing.allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();

    // Create a table with schema
    const schema = [_]ast_mod.ColumnDef{
        .{ .name = "id", .data_type = .int },
        .{ .name = "name", .data_type = .varchar },
        .{ .name = "active", .data_type = .bool },
    };
    try catalog.create_table("employees", &schema);
    const table = catalog.get_table("employees").?;

    // Insert 5 rows using InsertExecutor
    const rows = [_]struct { id: u64, name: []const u8, active: bool }{
        .{ .id = 1, .name = "alice", .active = true },
        .{ .id = 2, .name = "bob", .active = false },
        .{ .id = 3, .name = "charlie", .active = true },
        .{ .id = 4, .name = "diana", .active = false },
        .{ .id = 5, .name = "eve", .active = true },
    };

    for (rows) |row| {
        const vals = [_]ast_mod.Value{
            .{ .int = row.id },
            .{ .varchar = row.name },
            .{ .bool = row.active },
        };
        var insert_exec = exec.InsertExecutor{
            .table = table,
            .values = &vals,
            .txn_ctx = null,
            .allocator = std.testing.allocator,
        };
        try insert_exec.open();
        _ = try insert_exec.next();
    }

    // ── SeqScan: should return all 5 rows ──
    {
        var seq = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        try seq.open();
        defer seq.close();

        var count: usize = 0;
        while (try seq.next()) |tuple| {
            defer exec.free_tuple(std.testing.allocator, tuple);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 5), count);
    }

    // ── IndexScan eq: should return exactly 1 row for key=3 ──
    {
        var idx = exec.IndexScanExecutor{
            .table = table,
            .condition = .{ .eq = .{ .key = 3 } },
            .allocator = std.testing.allocator,
        };
        try idx.open();
        defer idx.close();

        const tuple = (try idx.next()).?;
        defer exec.free_tuple(std.testing.allocator, tuple);
        try std.testing.expectEqual(@as(u64, 3), tuple[0].int);
        try std.testing.expectEqualStrings("charlie", tuple[1].varchar);
        try std.testing.expectEqual(true, tuple[2].bool);

        // No more rows
        try std.testing.expectEqual(@as(?[]ast_mod.Value, null), try idx.next());
    }

    // ── IndexScan range: keys 2..4 should return 3 rows ──
    {
        var idx = exec.IndexScanExecutor{
            .table = table,
            .condition = .{ .range = .{ .start = 2, .end = 4 } },
            .allocator = std.testing.allocator,
        };
        try idx.open();
        defer idx.close();

        var count: usize = 0;
        while (try idx.next()) |tuple| {
            defer exec.free_tuple(std.testing.allocator, tuple);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);
    }

    // ── Filter over SeqScan: only rows with key >= 3 ──
    {
        var seq = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        var filter = exec.FilterExecutor{
            .child = .{ .seq_scan = &seq },
            .expression = .{ .compare = .{ .column = "id", .op = .gte, .value = .{ .int = 3 } } },
            .schema = table.schema,
            .allocator = std.testing.allocator,
        };
        var executor: exec.Executor = .{ .filter = &filter };
        try executor.open();
        defer executor.close();

        var count: usize = 0;
        while (try executor.next()) |tuple| {
            defer exec.free_tuple(std.testing.allocator, tuple);
            try std.testing.expect(tuple[0].int >= 3);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);
    }

    // ── Project over SeqScan: only select 'name' and 'active' ──
    {
        var seq = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        // columns 'name' (index 1) and 'active' (index 2)
        var cols = [_]usize{ 1, 2 };
        var project = exec.ProjectExecutor{
            .child = .{ .seq_scan = &seq },
            .column_indices = &cols,
            .allocator = std.testing.allocator,
        };
        var executor: exec.Executor = .{ .project = &project };
        try executor.open();
        defer executor.close();

        var count: usize = 0;
        while (try executor.next()) |tuple| {
            defer exec.free_tuple(std.testing.allocator, tuple);
            try std.testing.expectEqual(@as(usize, 2), tuple.len);
            try std.testing.expect(tuple[0] == .varchar);
            try std.testing.expect(tuple[1] == .bool);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 5), count);
    }

    // ── NestedLoopJoin: join table with itself where t1.id = t2.id ──
    {
        var seq_left = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        var left_executor: exec.Executor = .{ .seq_scan = &seq_left };

        var seq_right = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        var right_executor: exec.Executor = .{ .seq_scan = &seq_right };

        var join_exec = exec.NestedLoopJoinExecutor{
            .left_child = &left_executor,
            .right_child = &right_executor,
            .join_condition = .{ .column_compare = .{ .left_column = "id", .op = .eq, .right_column = "id" } },
            .join_type = .inner,
            .left_schema = table.schema,
            .right_schema = table.schema,
            .allocator = std.testing.allocator,
        };
        var executor: exec.Executor = .{ .nested_loop_join = &join_exec };
        try executor.open();
        defer executor.close();

        var count: usize = 0;
        while (try executor.next()) |tuple| {
            defer exec.free_tuple(std.testing.allocator, tuple);
            // joined tuple should have 3 + 3 = 6 columns
            try std.testing.expectEqual(@as(usize, 6), tuple.len);
            // t1.id == t2.id
            try std.testing.expectEqual(tuple[0].int, tuple[3].int);
            count += 1;
        }
        // Since it's a join on id (primary key), we expect 5 rows
        try std.testing.expectEqual(@as(usize, 5), count);
    }

    // ── SortMergeJoin: join table with itself where t1.id = t2.id ──
    {
        var seq_left = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        var left_executor: exec.Executor = .{ .seq_scan = &seq_left };

        var seq_right = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        var right_executor: exec.Executor = .{ .seq_scan = &seq_right };

        var sort_merge_join_exec = exec.SortMergeJoinExecutor{
            .left_child = &left_executor,
            .right_child = &right_executor,
            .left_join_col_idx = 0, // id is at index 0
            .right_join_col_idx = 0,
            .allocator = std.testing.allocator,
        };
        var executor: exec.Executor = .{ .sort_merge_join = &sort_merge_join_exec };
        try executor.open();
        defer executor.close();

        var count: usize = 0;
        while (try executor.next()) |tuple| {
            defer exec.free_tuple(std.testing.allocator, tuple);
            try std.testing.expectEqual(@as(usize, 6), tuple.len);
            try std.testing.expectEqual(tuple[0].int, tuple[3].int);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 5), count);
    }

    // ── AggregateExecutor: count tuples ──
    {
        var seq = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        const child_exec: exec.Executor = .{ .seq_scan = &seq };

        var agg = exec.AggregateExecutor{
            .child = child_exec,
            .group_by_col_idx = null, // Global count
            .agg_op = .count,
            .agg_col_idx = null,
            .allocator = std.testing.allocator,
        };
        var executor: exec.Executor = .{ .aggregate = &agg };
        try executor.open();
        defer executor.close();

        var yield_count: usize = 0;
        while (try executor.next()) |tuple| {
            defer exec.free_tuple(std.testing.allocator, tuple);
            try std.testing.expectEqual(@as(usize, 1), tuple.len); // only yields the count
            try std.testing.expectEqual(@as(u64, 5), tuple[0].int); // 5 rows inserted
            yield_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), yield_count); // 1 global aggregate row
    }

    // ── DeleteExecutor: delete key=2, then verify 4 remain ──
    {
        var index_exec = exec.IndexScanExecutor{
            .table = table,
            .condition = .{ .eq = .{ .key = 2 } },
            .allocator = std.testing.allocator,
            .txn_ctx = null,
        };
        var base_executor: exec.Executor = .{ .index_scan = &index_exec };
        var del = exec.DeleteExecutor{
            .table = table,
            .child = &base_executor,
            .txn_ctx = null,
            .allocator = std.testing.allocator,
        };
        try del.open();
        defer del.close();
        _ = try del.next();

        var seq = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        try seq.open();
        defer seq.close();
        var count: usize = 0;
        while (try seq.next()) |tuple| {
            defer exec.free_tuple(std.testing.allocator, tuple);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 4), count);
    }

    // ── UpdateExecutor: update name to 'updated_alice' where id=1 ──
    {
        var index_exec = exec.IndexScanExecutor{
            .table = table,
            .condition = .{ .eq = .{ .key = 1 } },
            .allocator = std.testing.allocator,
            .txn_ctx = null,
        };
        var base_executor: exec.Executor = .{ .index_scan = &index_exec };
        var upd = exec.UpdateExecutor{
            .table = table,
            .child = &base_executor,
            .column_name = "name",
            .new_value = .{ .varchar = "updated_alice" },
            .txn_ctx = null,
            .allocator = std.testing.allocator,
        };
        try upd.open();
        defer upd.close();
        _ = try upd.next();

        // Verify update
        var idx = exec.IndexScanExecutor{
            .table = table,
            .condition = .{ .eq = .{ .key = 1 } },
            .allocator = std.testing.allocator,
        };
        try idx.open();
        defer idx.close();
        const tuple = (try idx.next()).?;
        defer exec.free_tuple(std.testing.allocator, tuple);
        try std.testing.expectEqualStrings("updated_alice", tuple[1].varchar);
    }

    // ── OrderByExecutor & LimitExecutor ──
    {
        var seq = exec.SeqScanExecutor{
            .table = table,
            .allocator = std.testing.allocator,
        };
        var base_executor: exec.Executor = .{ .seq_scan = &seq };

        // Order by ID DESC
        const ob_exprs = [_]ast_mod.OrderByExpr{ .{ .column = "id", .is_desc = true } };
        var order_by_exec = exec.OrderByExecutor{
            .child = &base_executor,
            .order_by_exprs = &ob_exprs,
            .schema = table.schema,
            .allocator = std.testing.allocator,
        };
        var ob_executor: exec.Executor = .{ .order_by = &order_by_exec };

        // LIMIT 2 OFFSET 1
        var limit_exec = exec.LimitExecutor{
            .child = &ob_executor,
            .limit = 2,
            .offset = 1,
            .allocator = std.testing.allocator,
        };
        var executor: exec.Executor = .{ .limit = &limit_exec };

        try executor.open();
        defer executor.close();

        // Remaining IDs after delete(2): 1, 3, 4, 5
        // Sorted DESC: 5, 4, 3, 1
        // Offset 1, Limit 2: should be 4, 3
        const res1 = (try executor.next()).?;
        defer exec.free_tuple(std.testing.allocator, res1);
        try std.testing.expectEqual(@as(u64, 4), res1[0].int);

        const res2 = (try executor.next()).?;
        defer exec.free_tuple(std.testing.allocator, res2);
        try std.testing.expectEqual(@as(u64, 3), res2[0].int);

        // No more rows
        try std.testing.expectEqual(@as(?[]ast_mod.Value, null), try executor.next());
    }
}

test "Extended Data Types and Advanced Aggregations" {
    const ast = @import("query/ast.zig");
    const exec = @import("query/executor.zig");
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const test_db = "data/test_extended.db";
    std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    
    var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();
    
    var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();
    
    var next_page_counter: u32 = 1;
    var catalog = try Catalog.init(std.testing.allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();
    
    // Create table with all types
    const schema = [_]ast.ColumnDef{
        .{ .name = "id", .data_type = .int },
        .{ .name = "category", .data_type = .varchar },
        .{ .name = "price", .data_type = .float },
        .{ .name = "score", .data_type = .signed_int },
        .{ .name = "meta", .data_type = .json },
    };
    try catalog.create_table("products", &schema);
    const table = catalog.get_table("products").?;
    
    // Insert products
    const t1 = try table.serialize_tuple(std.testing.allocator, &[_]ast.Value{
        .{ .int = 1 }, .{ .varchar = "electronics" }, .{ .float = 299.99 }, .{ .signed_int = 5 }, .{ .json = "{\"brand\":\"Sony\"}" }
    });
    defer std.testing.allocator.free(t1);
    _ = try table.insert(null, 1, t1);
    
    const t2 = try table.serialize_tuple(std.testing.allocator, &[_]ast.Value{
        .{ .int = 2 }, .{ .varchar = "electronics" }, .{ .float = 150.00 }, .{ .signed_int = 4 }, .{ .json = "{\"brand\":\"LG\"}" }
    });
    defer std.testing.allocator.free(t2);
    _ = try table.insert(null, 2, t2);
    
    const t3 = try table.serialize_tuple(std.testing.allocator, &[_]ast.Value{
        .{ .int = 3 }, .{ .varchar = "books" }, .{ .float = 20.50 }, .{ .signed_int = -1 }, .{ .json = "{\"pages\":300}" }
    });
    defer std.testing.allocator.free(t3);
    _ = try table.insert(null, 3, t3);
    
    const t4 = try table.serialize_tuple(std.testing.allocator, &[_]ast.Value{
        .{ .int = 4 }, .{ .varchar = "books" }, .{ .float = 15.00 }, .{ .signed_int = 2 }, .{ .json = "{\"pages\":150}" }
    });
    defer std.testing.allocator.free(t4);
    _ = try table.insert(null, 4, t4);
    
    // Test Group By Aggregation: SUM(price) GROUP BY category
    var seq = exec.SeqScanExecutor{
        .table = table,
        .allocator = std.testing.allocator,
    };
    const child_exec: exec.Executor = .{ .seq_scan = &seq };

    var agg = exec.AggregateExecutor{
        .child = child_exec,
        .group_by_col_idx = 1, // category
        .agg_op = .sum,
        .agg_col_idx = 2, // price
        .allocator = std.testing.allocator,
    };
    var executor: exec.Executor = .{ .aggregate = &agg };
    try executor.open();
    defer executor.close();

    var result_count: usize = 0;
    var elec_sum: f64 = 0;
    var books_sum: f64 = 0;
    
    while (try executor.next()) |tuple| {
        defer exec.free_tuple(std.testing.allocator, tuple);
        try std.testing.expectEqual(@as(usize, 2), tuple.len);
        
        if (std.mem.eql(u8, tuple[0].varchar, "electronics")) {
            elec_sum = tuple[1].float;
        } else if (std.mem.eql(u8, tuple[0].varchar, "books")) {
            books_sum = tuple[1].float;
        }
        result_count += 1;
    }
    
    try std.testing.expectEqual(@as(usize, 2), result_count); // 2 categories
    try std.testing.expect(elec_sum == 449.99);
    try std.testing.expect(books_sum == 35.50);
}

test "BTree concurrent insertions" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "data/test_btree_concurrent.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    
    var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;

    // Allocate root for BTree
    const root_page_id = next_page_counter;
    next_page_counter += 1;
    {
        const root_frame = try buffer_mgr.new_frame(root_page_id);
        _ = @import("storage/index/btree_node.zig").BTreeNodeView.init(&root_frame.page, .leaf);
        buffer_mgr.unpin_frame(root_frame, true);
    }

    var btree = try BTree.init(&buffer_mgr, root_page_id, &next_page_counter);
    
    const num_threads = 4;
    const inserts_per_thread = 500;
    
    const Worker = struct {
        fn run(tree: *BTree, start_key: u64, count: u64) !void {
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const key = start_key + i;
                try tree.insert(null, key, key * 10);
            }
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    
    for (0..num_threads) |t_idx| {
        threads[t_idx] = try std.Thread.spawn(.{}, Worker.run, .{ &btree, @as(u64, @intCast(t_idx)) * inserts_per_thread, inserts_per_thread });
    }
    
    for (0..num_threads) |t_idx| {
        threads[t_idx].join();
    }
    
    // Verify all keys were inserted
    var total_found: usize = 0;
    for (0..num_threads) |t_idx| {
        const start = @as(u64, @intCast(t_idx)) * inserts_per_thread;
        for (0..inserts_per_thread) |i| {
            const key = start + i;
            const val = try btree.search(key);
            if (val != null and val.? == key * 10) {
                total_found += 1;
            }
        }
    }
    
    try std.testing.expectEqual(@as(usize, num_threads * inserts_per_thread), total_found);
}

test "BTree extensive deletions and merges" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "data/test_btree_merge.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    
    var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;

    // Allocate root for BTree
    const root_page_id = next_page_counter;
    next_page_counter += 1;
    {
        const root_frame = try buffer_mgr.new_frame(root_page_id);
        _ = @import("storage/index/btree_node.zig").BTreeNodeView.init(&root_frame.page, .leaf);
        buffer_mgr.unpin_frame(root_frame, true);
    }

    var btree = try BTree.init(&buffer_mgr, root_page_id, &next_page_counter);
    
    // Insert 1000 keys
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        try btree.insert(null, i, i * 10);
    }
    
    // Scan and assert 1000 elements exist
    const initial_rids = try btree.scan(std.testing.allocator, 0, 2000);
    defer std.testing.allocator.free(initial_rids);
    try std.testing.expectEqual(@as(usize, 1000), initial_rids.len);

    // Delete 500 keys (even numbers)
    i = 0;
    while (i < 1000) : (i += 2) {
        try btree.delete(null, i);
    }

    // Scan again, expecting 500
    const final_rids = try btree.scan(std.testing.allocator, 0, 2000);
    defer std.testing.allocator.free(final_rids);
    try std.testing.expectEqual(@as(usize, 500), final_rids.len);
    
    // Ensure all odd numbers exist
    i = 1;
    while (i < 1000) : (i += 2) {
        const val = try btree.search(i);
        try std.testing.expect(val != null);
        try std.testing.expectEqual(i * 10, val.?);
    }
}

test "Secondary Index" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "data/test_secondary_index.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, "sys_tables") catch {};
    
    var storage_mgr = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(std.testing.allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;
    var catalog = try Catalog.init(std.testing.allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();
    
    const Server = @import("server/server.zig").Server;
    var server = try Server.init(std.testing.allocator, io, 8080, &catalog, null);

    // CREATE TABLE
    const schema = [_]@import("query/ast.zig").ColumnDef{
        .{ .name = "id", .data_type = .int },
        .{ .name = "name", .data_type = .varchar },
        .{ .name = "age", .data_type = .int },
    };
    try server.execute_statement(.{ .create_table = .{ .table_name = "users", .columns = &schema } }, null, null, null);
    
    // INSERT
    try server.execute_statement(.{ .insert = .{ .table_name = "users", .values = &[_]@import("query/ast.zig").Value{ .{ .int = 1 }, .{ .varchar = "alice" }, .{ .int = 30 } } } }, null, null, null);
    try server.execute_statement(.{ .insert = .{ .table_name = "users", .values = &[_]@import("query/ast.zig").Value{ .{ .int = 2 }, .{ .varchar = "bob" }, .{ .int = 25 } } } }, null, null, null);
    try server.execute_statement(.{ .insert = .{ .table_name = "users", .values = &[_]@import("query/ast.zig").Value{ .{ .int = 3 }, .{ .varchar = "charlie" }, .{ .int = 30 } } } }, null, null, null);
    
    // CREATE INDEX
    try server.execute_statement(.{ .create_index = .{ .index_name = "idx_age", .table_name = "users", .column_name = "age", .index_type = .btree } }, null, null, null);

    const cond = @import("query/ast.zig").Expression{
        .compare = .{ .column = "age", .op = .eq, .value = .{ .int = 30 } }
    };
    try server.execute_statement(.{ .select = .{ 
        .table_name = "users", 
        .columns = &[_][]const u8{"name"}, 
        .condition = cond,
        .aggregates = null, .window_functions = null,
        .join_type = .inner,
        .join_table = null,
        .join_condition = null,
        .group_by = null,
        .order_by = null,
        .limit = null,
        .offset = null,
    } }, null, null, null);
}

