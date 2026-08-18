const std = @import("std");
const sm = @import("storage/storage_manager/storage_manager.zig");
const BufferManager = @import("storage/buffer_manager/buffer_manager.zig").BufferManager;
const BTree = @import("storage/index/btree.zig").BTree;
const Table = @import("storage/table.zig").Table;
const page = @import("storage/page/page.zig");
const LogManager = @import("storage/wal/log_manager.zig").LogManager;
const RecoveryManager = @import("storage/wal/recovery_manager.zig").RecoveryManager;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;



    // Start server
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();

    const io = threaded_io.io();

    var storage_mgr = try sm.StorageManager.init(allocator, io, "data/simple.db");
    try storage_mgr.start();
    defer storage_mgr.deinit();

    const dir = std.Io.Dir.cwd();
    const wal_file = try std.Io.Dir.createFile(dir, io, "data/simpledb.wal", .{ .read = true, .truncate = false });
    var log_mgr = try LogManager.init(io, wal_file);

    var buffer_mgr = try BufferManager.init(allocator, &storage_mgr);
    try buffer_mgr.start();
    buffer_mgr.log_manager = &log_mgr;
    defer buffer_mgr.deinit();

    // Run Recovery Before Catalog Init (which fetches pages)
    var recovery_mgr = RecoveryManager.init(io, allocator, &log_mgr, &buffer_mgr);
    defer recovery_mgr.deinit();
    try recovery_mgr.recover();

    var next_page_counter: u32 = 1;

    const Catalog = @import("storage/catalog.zig").Catalog;
    var catalog = try Catalog.init(allocator, &buffer_mgr, &next_page_counter);

    std.debug.print("==================================\n", .{});
    std.debug.print("SimpleDB: Tables & Concurrency!\n", .{});
    std.debug.print("==================================\n", .{});

    var server = try @import("server/server.zig").Server.init(allocator, io, 8080, &catalog);

    var cli_mode = false;
    var args_it = init.minimal.args.iterate();
    _ = args_it.skip();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cli")) {
            cli_mode = true;
        }
    }

    if (cli_mode) {
        try @import("cli.zig").run_cli(allocator, &server, &catalog);
    } else {
        std.debug.print("Starting SimpleDB TCP Server on port 8080...\n", .{});
        try server.start();
    }
}
