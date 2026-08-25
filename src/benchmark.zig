const std = @import("std");
const sm = @import("storage/storage_manager/storage_manager.zig");
const bm = @import("storage/buffer_manager/buffer_manager.zig");
const BTree = @import("storage/index/btree.zig").BTree;
const Table = @import("storage/table.zig").Table;
const Catalog = @import("storage/catalog.zig").Catalog;

pub fn main(init: std.process.Init) !void {
    const DebugAllocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true });
    var allocator_state = DebugAllocator{};
    const allocator = allocator_state.allocator();
    defer _ = allocator_state.deinit();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var run_buffer = false;
    var run_btree = false;
    var run_table = false;
    var run_parser = false;
    var run_execution = false;
    var run_transaction = false;
    var run_eviction = false;
    var run_lock_manager = false;
    var run_secondary_index = false;
    var run_scan_resistance = false;
    var run_mvcc = false;
    var run_all = true;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "buffer")) {
            run_buffer = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "btree")) {
            run_btree = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "table")) {
            run_table = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "parser")) {
            run_parser = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "execution")) {
            run_execution = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "transaction")) {
            run_transaction = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "eviction")) {
            run_eviction = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "lock_manager")) {
            run_lock_manager = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "secondary_index")) {
            run_secondary_index = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "scan_resistance")) {
            run_scan_resistance = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "mvcc")) {
            run_mvcc = true;
            run_all = false;
        } else if (std.mem.eql(u8, arg, "all")) {
            run_all = true;
        }
    }

    std.debug.print("Running SimpleDB Benchmarks...\n================================\n", .{});

    if (run_all or run_buffer) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_buffer_manager(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_btree) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_btree(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_table) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_table(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_parser) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_parser(allocator);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_execution) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_execution(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_transaction) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_transaction(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_eviction) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_eviction(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_lock_manager) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_lock_manager(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_secondary_index) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_secondary_index(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_scan_resistance) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_scan_resistance(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }
    if (run_all or run_mvcc) {
        const before = allocator_state.total_requested_bytes;
        try benchmark_mvcc(allocator, io);
        std.debug.print("Memory used: {d} bytes\n", .{allocator_state.total_requested_bytes - before});
    }

    std.debug.print("================================\nBenchmarks completed successfully.\n", .{});
}

fn get_time_ms() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1000000;
}

fn benchmark_buffer_manager(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: Buffer Manager]\n", .{});

    const test_db = "data/bench_buffer.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    // Prepare pages
    var empty_page = std.mem.zeroes(@import("storage/page/page.zig").Page);
    const num_pages = 100000;

    for (0..num_pages) |i| {
        try storage_mgr.write_page(@intCast(i), &empty_page);
    }

    // Sequential Scan
    const start_time = get_time_ms();
    for (0..5) |_| {
        for (0..num_pages) |i| {
            if (i % 10000 == 0) std.debug.print("SeqFetch Page {d}\n", .{i});
            const frame = try buffer_mgr.fetch_frame(@intCast(i));
            // Read something to prevent optimization
            _ = frame.page_id;
            buffer_mgr.unpin_frame(frame, false);
        }
    }
    const end_time = get_time_ms();
    const elapsed = end_time - start_time;
    std.debug.print("Sequential Fetch & Pin (100k pages, 5x): {d} ms\n", .{elapsed});
}

fn benchmark_btree(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: BTree]\n", .{});

    const test_db = "data/bench_btree.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(allocator, &storage_mgr);
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

    const num_records = 10000000; // 10M records

    var start_time = get_time_ms();

    var i: u64 = 0;
    while (i < num_records) : (i += 1) {
        try btree.insert(null, i, i * 10);
    }
    const insert_elapsed = get_time_ms() - start_time;
    std.debug.print("BTree Insert (10M records): {d} ms\n", .{insert_elapsed});

    start_time = get_time_ms();
    for (0..2) |_| {
        i = 0;
        while (i < num_records) : (i += 1) {
            _ = try btree.search(i);
        }
    }
    const search_elapsed = get_time_ms() - start_time;
    std.debug.print("BTree Search (10M records, 2x): {d} ms\n", .{search_elapsed});
}

fn benchmark_table(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: Table]\n", .{});

    const test_db = "data/bench_table.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;

    var catalog = try Catalog.init(allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();

    const schema = [_]@import("query/ast.zig").ColumnDef{
        .{ .name = "id", .data_type = .int },
        .{ .name = "name", .data_type = .varchar },
    };
    try catalog.create_table("bench_users", &schema);
    const table = catalog.get_table("bench_users").?;

    const num_records = 2000000; // 2M records

    var start_time = get_time_ms();

    var i: u64 = 0;
    while (i < num_records) : (i += 1) {
        _ = try table.insert(null, i, "user_data_payload_12345");
    }
    const insert_elapsed = get_time_ms() - start_time;
    std.debug.print("Table Insert (2M records): {d} ms\n", .{insert_elapsed});

    start_time = get_time_ms();
    for (0..2) |_| {
        i = 0;
        while (i < num_records) : (i += 1) {
            if (try table.search(allocator, null, i)) |val| {
                allocator.free(val);
            }
        }
    }
    const search_elapsed = get_time_ms() - start_time;
    std.debug.print("Table Search (2M records, 2x): {d} ms\n", .{search_elapsed});
}

fn benchmark_parser(allocator: std.mem.Allocator) !void {
    std.debug.print("\n[Benchmark: Parser]\n", .{});
    const Parser = @import("query/parser.zig").Parser;

    const query =
        \\SELECT id, name, age, salary FROM employees 
        \\WHERE age > 30 AND salary < 100000 
        \\ORDER BY age DESC LIMIT 10;
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const num_iterations = 1000000; // 1M times
    const start_time = get_time_ms();

    for (0..num_iterations) |_| {
        var p = Parser.init(query, arena.allocator());
        _ = try p.parse_statement();
        _ = arena.reset(.retain_capacity);
    }

    const elapsed = get_time_ms() - start_time;
    std.debug.print("Parser (1M complex queries): {d} ms\n", .{elapsed});
}

fn benchmark_execution(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: Execution]\n", .{});
    const exec = @import("query/executor.zig");

    const test_db = "data/bench_exec.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;

    var catalog = try Catalog.init(allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();

    const schema = [_]@import("query/ast.zig").ColumnDef{
        .{ .name = "id", .data_type = .int },
        .{ .name = "name", .data_type = .varchar },
    };
    try catalog.create_table("bench_exec_table", &schema);
    const table = catalog.get_table("bench_exec_table").?;

    const num_records = 500000;

    const ast = @import("query/ast.zig");
    const t1 = try table.serialize_tuple(allocator, &[_]ast.Value{ .{ .int = 1 }, .{ .varchar = "payload" } });
    defer allocator.free(t1);

    for (0..num_records) |i| {
        _ = try table.insert(null, i, t1);
    }

    const start_time = get_time_ms();

    var seq = exec.SeqScanExecutor{
        .table = table,
        .allocator = allocator,
    };
    var filter = exec.FilterExecutor{
        .child = .{ .seq_scan = &seq },
        .expression = .{ .compare = .{ .column = "id", .op = .gte, .value = .{ .int = 100000 } } },
        .schema = table.schema,
        .allocator = allocator,
    };
    var executor: exec.Executor = .{ .filter = &filter };
    try executor.open();
    defer executor.close();

    var count: usize = 0;
    while (try executor.next()) |tuple| {
        defer exec.free_tuple(allocator, tuple);
        count += 1;
    }
    const elapsed = get_time_ms() - start_time;
    std.debug.print("Executor Filter Scan (500k rows, found {d}): {d} ms\n", .{ count, elapsed });
}

fn benchmark_transaction(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: Transaction & WAL]\n", .{});
    _ = allocator;
    const LogManager = @import("storage/wal/log_manager.zig").LogManager;

    const test_wal = "data/bench_txn.wal";
    defer std.Io.Dir.cwd().deleteFile(io, test_wal) catch {};

    const dir = std.Io.Dir.cwd();
    const wal_file = try std.Io.Dir.createFile(dir, io, test_wal, .{ .read = true, .truncate = true });
    var log_mgr = try LogManager.init(io, wal_file);
    defer wal_file.close(io);

    const start_time = get_time_ms();
    const num_txns = 100000;

    for (0..num_txns) |i| {
        var txn_ctx = @import("storage/wal/transaction.zig").TransactionContext{ .txn_id = @intCast(i + 1) };
        txn_ctx.prev_lsn = try log_mgr.append_record(txn_ctx.txn_id, 0, .insert_tuple, @intCast(i % 1000), 0, "test_payload");
        try log_mgr.flush(txn_ctx.prev_lsn);
    }

    const elapsed = get_time_ms() - start_time;
    std.debug.print("Transaction & WAL (100k commits): {d} ms\n", .{elapsed});
}

fn benchmark_eviction(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: Buffer Eviction]\n", .{});

    const test_db = "data/bench_evict.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    // Small buffer pool to force eviction
    var buffer_mgr = try bm.BufferManager.init(allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var empty_page = std.mem.zeroes(@import("storage/page/page.zig").Page);
    const num_pages = 2000;

    for (0..num_pages) |i| {
        try storage_mgr.write_page(@intCast(i), &empty_page);
    }

    const start_time = get_time_ms();
    const iterations = 50;

    for (0..iterations) |_| {
        for (0..num_pages) |i| {
            const frame = try buffer_mgr.fetch_frame(@intCast(i));
            buffer_mgr.unpin_frame(frame, false);
        }
    }

    const elapsed = get_time_ms() - start_time;
    std.debug.print("Clock Sweep Eviction (100k fetch/evict cycles): {d} ms\n", .{elapsed});
}

fn benchmark_lock_manager(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: Lock Manager]\n", .{});
    const LockManager = @import("storage/concurrency/lock_manager.zig").LockManager;

    var lock_mgr = LockManager.init(allocator, io);
    defer lock_mgr.deinit();

    const num_locks = 1000000;
    const start_time = get_time_ms();

    for (0..num_locks) |i| {
        try lock_mgr.lock_exclusive(1, @intCast(i));
        lock_mgr.unlock(1, @intCast(i));
    }

    const elapsed = get_time_ms() - start_time;
    std.debug.print("Lock Manager (1M Exclusive Lock/Unlock pairs): {d} ms\n", .{elapsed});
}

fn benchmark_secondary_index(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: Secondary Index]\n", .{});
    const exec = @import("query/executor.zig");

    const test_db = "data/bench_sec_idx.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;

    var catalog = try Catalog.init(allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();

    const schema = [_]@import("query/ast.zig").ColumnDef{
        .{ .name = "id", .data_type = .int },
        .{ .name = "age", .data_type = .int },
    };
    try catalog.create_table("bench_users", &schema);
    const table = catalog.get_table("bench_users").?;

    const num_records = 500000; // 500k

    const ast = @import("query/ast.zig");
    for (0..num_records) |i| {
        const t1 = try table.serialize_tuple(allocator, &[_]ast.Value{ .{ .int = @intCast(i) }, .{ .int = @intCast(i % 100) } });
        defer allocator.free(t1);
        _ = try table.insert(null, @intCast(i), t1);
    }

    var start_time = get_time_ms();
    try catalog.create_index("idx_age", "bench_users", "age", .btree);
    var elapsed = get_time_ms() - start_time;
    std.debug.print("Secondary Index Creation (500k records backfill): {d} ms\n", .{elapsed});

    start_time = get_time_ms();
    for (0..100) |i| {
        var idx = exec.IndexScanExecutor{
            .table = table,
            .condition = .{ .eq = .{ .key = @intCast(i) } },
            .index_def = table.indexes.get("idx_age").?,
            .allocator = allocator,
        };
        try idx.open();
        var count: usize = 0;
        while (try idx.next()) |tuple| {
            defer exec.free_tuple(allocator, tuple);
            count += 1;
        }
        idx.close();
    }
    elapsed = get_time_ms() - start_time;
    std.debug.print("Secondary Index Scan (100 point queries, ~5k hits each): {d} ms\n", .{elapsed});
}

fn benchmark_scan_resistance(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: Scan Resistance]\n", .{});

    const test_db = "data/bench_scan_res.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    // pool_size is 4096.
    var buffer_mgr = try bm.BufferManager.init(allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var empty_page = std.mem.zeroes(@import("storage/page/page.zig").Page);
    const num_pages = 20000;

    for (0..num_pages) |i| {
        try storage_mgr.write_page(@intCast(i), &empty_page);
    }

    // 1. Establish 1000 hot pages
    for (0..5) |_| {
        for (0..1000) |i| {
            const frame = try buffer_mgr.fetch_frame(@intCast(i));
            buffer_mgr.unpin_frame(frame, false);
        }
    }

    // 2. Perform a massive sequential scan that exceeds pool size (e.g. 10000 pages)
    for (1000..11000) |i| {
        const frame = try buffer_mgr.fetch_frame(@intCast(i));
        buffer_mgr.unpin_frame(frame, false);
    }

    // 3. Fetch hot pages again and measure time
    const start_time = get_time_ms();
    for (0..1000) |i| {
        const frame = try buffer_mgr.fetch_frame(@intCast(i));
        buffer_mgr.unpin_frame(frame, false);
    }
    const elapsed = get_time_ms() - start_time;

    std.debug.print("Scan Resistance (1000 hot pages hit after 10k scan): {d} ms\n", .{elapsed});
}

fn benchmark_mvcc(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("\n[Benchmark: MVCC Concurrency & Version Churn]\n", .{});
    const exec = @import("query/executor.zig");

    const test_db = "data/bench_mvcc.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var storage_mgr = try sm.StorageManager.init(allocator, io, test_db);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    var buffer_mgr = try bm.BufferManager.init(allocator, &storage_mgr);
    try buffer_mgr.start();
    defer buffer_mgr.deinit();

    var next_page_counter: u32 = 1;

    var catalog = try Catalog.init(allocator, &buffer_mgr, &next_page_counter);
    defer catalog.deinit();

    const schema = [_]@import("query/ast.zig").ColumnDef{
        .{ .name = "id", .data_type = .int },
        .{ .name = "balance", .data_type = .int },
    };
    try catalog.create_table("accounts", &schema);
    const table = catalog.get_table("accounts").?;

    const num_records = 20000;
    const num_updates = 10;

    var start_time = get_time_ms();

    // 1. Initial Insertions
    var txn_insert = @import("storage/wal/transaction.zig").TransactionContext{ .txn_id = 1 };

    const ast = @import("query/ast.zig");
    for (0..num_records) |i| {
        const t1 = try table.serialize_tuple(allocator, &[_]ast.Value{ .{ .int = @intCast(i) }, .{ .int = 100 } });
        defer allocator.free(t1);
        _ = try table.insert(&txn_insert, @intCast(i), t1);
    }
    var elapsed = get_time_ms() - start_time;
    std.debug.print("Initial Inserts (20k rows): {d} ms\n", .{elapsed});

    // 2. Baseline Scan Time
    start_time = get_time_ms();
    var seq_base = exec.SeqScanExecutor{
        .table = table,
        .txn_ctx = &txn_insert,
        .allocator = allocator,
    };
    try seq_base.open();
    var count: usize = 0;
    while (try seq_base.next()) |tuple| {
        defer exec.free_tuple(allocator, tuple);
        count += 1;
    }
    seq_base.close();
    const baseline_elapsed = get_time_ms() - start_time;
    std.debug.print("Baseline SeqScan (20k rows, no churn): {d} ms\n", .{baseline_elapsed});

    // Snapshot for old reader
    var txn_old_reader = @import("storage/wal/transaction.zig").TransactionContext{ .txn_id = 2 };

    // 3. Update Churn (simulate heavy OLTP updates)
    start_time = get_time_ms();
    for (0..num_updates) |u| {
        var txn_update = @import("storage/wal/transaction.zig").TransactionContext{ .txn_id = @intCast(3 + u) };
        for (0..num_records) |i| {
            var index_exec = exec.IndexScanExecutor{
                .table = table,
                .condition = .{ .eq = .{ .key = @intCast(i) } },
                .allocator = allocator,
                .txn_ctx = &txn_update,
            };
            var base_executor: exec.Executor = .{ .index_scan = &index_exec };
            var upd = exec.UpdateExecutor{
                .table = table,
                .child = &base_executor,
                .column_name = "balance",
                .new_value = .{ .int = @intCast(100 + u + 1) },
                .txn_ctx = &txn_update,
                .allocator = allocator,
            };
            try upd.open();
            _ = try upd.next();
            upd.close();
        }
    }
    elapsed = get_time_ms() - start_time;
    std.debug.print("Update Churn (20k rows * 10 updates = 200k updates): {d} ms\n", .{elapsed});

    // 4. Stale Scan Time (Scanning past new versions)
    start_time = get_time_ms();
    var seq_old = exec.SeqScanExecutor{
        .table = table,
        .txn_ctx = &txn_old_reader,
        .allocator = allocator,
    };
    try seq_old.open();
    count = 0;
    while (try seq_old.next()) |tuple| {
        defer exec.free_tuple(allocator, tuple);
        count += 1;
    }
    seq_old.close();
    const stale_elapsed = get_time_ms() - start_time;
    std.debug.print("Stale SeqScan (reading oldest versions): {d} ms ({d}x degradation)\n", .{ stale_elapsed, stale_elapsed / @max(baseline_elapsed, 1) });

    // 5. Fresh Scan Time (Scanning past old versions)
    var txn_fresh = @import("storage/wal/transaction.zig").TransactionContext{ .txn_id = 1000 };
    start_time = get_time_ms();
    var seq_fresh = exec.SeqScanExecutor{
        .table = table,
        .txn_ctx = &txn_fresh,
        .allocator = allocator,
    };
    try seq_fresh.open();
    count = 0;
    while (try seq_fresh.next()) |tuple| {
        defer exec.free_tuple(allocator, tuple);
        count += 1;
    }
    seq_fresh.close();
    const fresh_elapsed = get_time_ms() - start_time;
    std.debug.print("Fresh SeqScan (reading newest versions): {d} ms ({d}x degradation)\n", .{ fresh_elapsed, fresh_elapsed / @max(baseline_elapsed, 1) });

    std.debug.print("Space Amplification: Database grew to {d} pages.\n", .{next_page_counter});
}
