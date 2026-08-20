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



    var cli_mode = false;
    var port: u16 = 8080;
    var replica_of: ?[]const u8 = null;

    var args_it = init.minimal.args.iterate();
    _ = args_it.skip();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cli")) {
            cli_mode = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args_it.next()) |p_arg| {
                port = std.fmt.parseInt(u16, p_arg, 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--replica-of")) {
            if (args_it.next()) |r_arg| {
                replica_of = r_arg;
            }
        }
    }

    // Start server
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();

    const io = threaded_io.io();

    var db_filename_buf: [128]u8 = undefined;
    const db_filename = try std.fmt.bufPrint(&db_filename_buf, "data/simple_{d}.db", .{port});
    var storage_mgr = try sm.StorageManager.init(allocator, io, db_filename);
    try storage_mgr.start();
    defer storage_mgr.deinit();

    const dir = std.Io.Dir.cwd();
    var wal_filename_buf: [128]u8 = undefined;
    const wal_filename = try std.fmt.bufPrint(&wal_filename_buf, "data/simpledb_{d}.wal", .{port});
    const wal_file = try std.Io.Dir.createFile(dir, io, wal_filename, .{ .read = true, .truncate = false });
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

    var server = try @import("server/server.zig").Server.init(allocator, io, port, &catalog, replica_of);

    if (cli_mode) {
        std.debug.print("Starting SimpleDB TCP Server on port {d} in background...\n", .{port});
        const server_thread = try std.Thread.spawn(.{}, @import("server/server.zig").Server.start, .{&server});
        server_thread.detach();
        try @import("cli.zig").run_cli(allocator, &server, &catalog);
    } else {
        std.debug.print("Starting SimpleDB TCP Server on port {d}...\n", .{port});
        try server.start();
    }
}
