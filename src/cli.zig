const std = @import("std");
const Server = @import("server/server.zig").Server;
const UndoOp = @import("server/undo.zig").UndoOp;
const clear_undo_stack = @import("server/undo.zig").clear_undo_stack;
const execute_undo_stack = @import("server/undo.zig").execute_undo_stack;
const Catalog = @import("storage/catalog.zig").Catalog;

const StdoutWriter = struct {
    pub fn print(self: StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        std.debug.print(fmt, args);
    }

    pub fn writeAll(self: StdoutWriter, data: []const u8) !void {
        _ = self;
        std.debug.print("{s}", .{data});
    }
};

pub fn run_cli(allocator: std.mem.Allocator, server: *Server, catalog: *Catalog) !void {
    const stdout = StdoutWriter{};
    try stdout.writeAll("Welcome to SimpleDB CLI!\nType .help for instructions, or .exit to quit.\n");

    var in_transaction = false;
    var txn_ctx: ?@import("storage/wal/transaction.zig").TransactionContext = null;
    var undo_stack = std.ArrayList(UndoOp).empty;
    defer undo_stack.deinit(allocator);
    defer clear_undo_stack(&undo_stack, allocator);

    // Release mutex if CLI dies mid-transaction
    defer {
        if (in_transaction) {
            execute_undo_stack(&undo_stack, catalog);
            if (catalog.buffer_manager.log_manager) |lm| {
                _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .abort, 0, 0, &[_]u8{}) catch 0;
            }
            server.active_txn_rwlock.unlock(server.io);
        }
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        if (in_transaction) {
            try stdout.writeAll("simpledb(txn)> ");
        } else {
            try stdout.writeAll("simpledb> ");
        }

        var len: usize = 0;
        var eof = false;
        while (len < buf.len - 1) {
            var b: [1]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &b) catch 0;
            if (n == 0) {
                eof = true;
                break;
            }
            if (b[0] == '\n') break;
            buf[len] = b[0];
            len += 1;
        }

        if (len == 0 and eof) break;

        const line = std.mem.trim(u8, buf[0..len], " \r");
        if (std.mem.eql(u8, line, ".exit") or std.mem.eql(u8, line, ".quit")) {
            break;
        }
        if (std.mem.eql(u8, line, ".help")) {
            try stdout.writeAll("Commands:\n  .exit\n  .help\n  SQL Statements (SELECT, INSERT, CREATE TABLE, BEGIN, COMMIT, ROLLBACK)\n");
            continue;
        }
        if (line.len == 0) continue;

        var parser = @import("query/parser.zig").Parser.init(line, allocator);
        const stmt = parser.parse_statement() catch |err| {
            try stdout.print("ERR PARSER: {}\n", .{err});
            continue;
        };

        defer {
            if (stmt == .create_table) {
                allocator.free(stmt.create_table.columns);
            } else if (stmt == .insert) {
                allocator.free(stmt.insert.values);
            } else if (stmt == .select) {
                if (stmt.select.columns) |cols| allocator.free(cols);
                if (stmt.select.aggregates) |aggs| allocator.free(aggs);
            }
        }

        var requires_exclusive_lock = false;
        var requires_shared_lock = false;

        switch (stmt) {
            .insert, .delete => requires_exclusive_lock = true,
            .create_table, .drop_table => requires_exclusive_lock = true,
            .select => requires_shared_lock = true,
            else => {},
        }

        var did_lock_exclusive_now = false;
        var did_lock_shared_now = false;
        if (!in_transaction) {
            if (requires_exclusive_lock) {
                server.active_txn_rwlock.lockUncancelable(server.io);
                did_lock_exclusive_now = true;
                txn_ctx = server.start_txn() catch |err| {
                    server.active_txn_rwlock.unlock(server.io);
                    try stdout.print("ERR {}\n", .{err});
                    continue;
                };
                if (catalog.buffer_manager.log_manager) |lm| {
                    txn_ctx.?.prev_lsn = lm.append_record(txn_ctx.?.txn_id, 0, .begin, 0, 0, &[_]u8{}) catch 0;
                }
            } else if (requires_shared_lock) {
                server.active_txn_rwlock.lockSharedUncancelable(server.io);
                did_lock_shared_now = true;
                txn_ctx = server.start_txn() catch |err| {
                    server.active_txn_rwlock.unlockShared(server.io);
                    try stdout.print("ERR {}\n", .{err});
                    continue;
                };
            }
        }
        if (stmt == .begin) {
            if (in_transaction) {
                try stdout.writeAll("ERR already in transaction\n");
                continue;
            }
            server.active_txn_rwlock.lockUncancelable(server.io);
            in_transaction = true;
            txn_ctx = server.start_txn() catch |err| {
                in_transaction = false;
                server.active_txn_rwlock.unlock(server.io);
                try stdout.print("ERR {}\n", .{err});
                continue;
            };
            if (catalog.buffer_manager.log_manager) |lm| {
                txn_ctx.?.prev_lsn = lm.append_record(txn_ctx.?.txn_id, 0, .begin, 0, 0, &[_]u8{}) catch 0;
            }
            try stdout.writeAll("OK\n");
            continue;
        } else if (stmt == .commit) {
            if (in_transaction) {
                if (catalog.buffer_manager.log_manager) |lm| {
                    _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .commit, 0, 0, &[_]u8{}) catch 0;
                }
                clear_undo_stack(&undo_stack, allocator);
                in_transaction = false;
                if (txn_ctx) |*ctx| server.end_txn(ctx);
                txn_ctx = null;
                server.active_txn_rwlock.unlock(server.io);
            }
            try stdout.writeAll("OK\n");
            continue;
        } else if (stmt == .rollback) {
            if (in_transaction) {
                execute_undo_stack(&undo_stack, catalog);
                if (catalog.buffer_manager.log_manager) |lm| {
                    _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .abort, 0, 0, &[_]u8{}) catch 0;
                }
                clear_undo_stack(&undo_stack, allocator);
                in_transaction = false;
                if (txn_ctx) |*ctx| server.end_txn(ctx);
                txn_ctx = null;
                server.active_txn_rwlock.unlock(server.io);
            }
            try stdout.writeAll("OK\n");
            continue;
        }

        var ctx_ptr: ?*@import("storage/wal/transaction.zig").TransactionContext = null;
        if (txn_ctx) |*ctx| {
            ctx_ptr = ctx;
        }

        server.execute_statement(stmt, ctx_ptr, stdout, if (in_transaction or did_lock_exclusive_now) &undo_stack else null) catch |err| {
            if (did_lock_exclusive_now) {
                if (catalog.buffer_manager.log_manager) |lm| {
                    _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .abort, 0, 0, &[_]u8{}) catch 0;
                }
                if (txn_ctx) |*ctx| server.end_txn(ctx);
                txn_ctx = null;
                server.active_txn_rwlock.unlock(server.io);
            } else if (did_lock_shared_now) {
                if (txn_ctx) |*ctx| server.end_txn(ctx);
                txn_ctx = null;
                server.active_txn_rwlock.unlockShared(server.io);
            }
            try stdout.print("ERR EXEC: {}\n", .{err});
            continue;
        };

        if (did_lock_exclusive_now) {
            if (catalog.buffer_manager.log_manager) |lm| {
                _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .commit, 0, 0, &[_]u8{}) catch 0;
            }
            clear_undo_stack(&undo_stack, allocator);
            if (txn_ctx) |*ctx| server.end_txn(ctx);
            txn_ctx = null;
            server.active_txn_rwlock.unlock(server.io);
        } else if (did_lock_shared_now) {
            if (txn_ctx) |*ctx| server.end_txn(ctx);
            txn_ctx = null;
            server.active_txn_rwlock.unlockShared(server.io);
        }

        if (stmt != .select) {
            try stdout.writeAll("OK\n");
        }
    }
}
