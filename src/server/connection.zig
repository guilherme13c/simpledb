const std = @import("std");
const ast = @import("../query/ast.zig");
const parser_mod = @import("../query/parser.zig");
const execution = @import("execution.zig");
const undo = @import("undo.zig");
const transaction = @import("../storage/wal/transaction.zig");

/// Handles an incoming client connection.
pub fn handleConnection(server: anytype, stream: std.Io.net.Stream) void {
    defer stream.close(server.io);
    std.debug.print("Handled connection successfully.\n", .{});

    var msg_buf: [131072]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(server.io, &write_buf);

    var in_transaction = false;
    var txn_ctx: ?transaction.TransactionContext = null;
    var undo_stack = std.ArrayList(undo.UndoOp).empty;
    defer undo_stack.deinit(server.allocator);
    defer undo.clear_undo_stack(&undo_stack, server.allocator);

    // Release mutex if connection dies mid-transaction
    defer {
        if (in_transaction) {
            undo.execute_undo_stack(&undo_stack, server.catalog);
            if (server.catalog.buffer_manager.log_manager) |lm| {
                _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .abort, 0, 0, &[_]u8{}) catch 0;
            }
            server.end_txn(&txn_ctx.?);
            server.active_txn_rwlock.unlock(server.io);
        }
    }

    var msg_len: usize = 0;
    while (true) {
        if (msg_len == msg_buf.len) break;
        const bytes_read = std.posix.read(stream.socket.handle, msg_buf[msg_len..]) catch break;
        if (bytes_read == 0) break;
        msg_len += bytes_read;

        while (std.mem.indexOfAny(u8, msg_buf[0..msg_len], "\r\n")) |idx| {
            var consume = idx + 1;
            if (consume < msg_len and msg_buf[consume] == '\n' and msg_buf[idx] == '\r') {
                consume += 1;
            }
            const line_slice = msg_buf[0..idx];
            const line = server.allocator.dupe(u8, line_slice) catch break;
            defer server.allocator.free(line);
            
            std.mem.copyForwards(u8, msg_buf[0 .. msg_len - consume], msg_buf[consume..msg_len]);
            msg_len -= consume;
            
            if (line.len == 0) continue;
                        if (std.mem.startsWith(u8, line, "ROUTER ADD ")) {
                var it = std.mem.tokenizeAny(u8, line, " ");
                _ = it.next();
                _ = it.next();
                if (it.next()) |node| {
                    server.hash_ring.add_node(node) catch |err| {
                        writer.interface.print("ERR {}\\n", .{err}) catch {};
                        writer.interface.flush() catch {};
                        continue;
                    };
                    writer.interface.writeAll("OK\\n") catch {};
                    writer.interface.flush() catch {};
                }
                continue;
            }
            if (std.mem.startsWith(u8, line, "ROUTER REMOVE ")) {
                var it = std.mem.tokenizeAny(u8, line, " ");
                _ = it.next();
                _ = it.next();
                if (it.next()) |node| {
                    server.hash_ring.remove_node(node);
                    writer.interface.writeAll("OK\\n") catch {};
                    writer.interface.flush() catch {};
                }
                continue;
            }
            if (std.mem.startsWith(u8, line, "ROUTER GET ")) {
                var it = std.mem.tokenizeAny(u8, line, " ");
                _ = it.next();
                _ = it.next();
                if (it.next()) |key| {
                    if (server.hash_ring.get_node(key)) |node| {
                        writer.interface.print("{s}\\n", .{node}) catch {};
                        writer.interface.flush() catch {};
                    } else {
                        writer.interface.writeAll("ERR no nodes in ring\\n") catch {};
                        writer.interface.flush() catch {};
                    }
                }
                continue;
            }
            if (std.mem.startsWith(u8, line, "RAFT_CONFIG_UPDATE ")) {
                if (server.raft) |raft| {
                    raft.handle_config_update(line, &writer.interface) catch |err| {
                        writer.interface.print("ERR {}\n", .{err}) catch {};
                        writer.interface.flush() catch {};
                    };
                }
                continue;
            }

            if (std.mem.startsWith(u8, line, "RAFT_")) {
                if (server.raft) |raft| {
                    raft.handle_message_tcp(line, &writer.interface) catch |err| {
                        std.debug.print("Error handling raft TCP msg: {}\n", .{err});
                    };
                }
                continue;
            }

            if (std.mem.startsWith(u8, line, "START_REPLICATION ")) {
                const lsn_str = line[18..];
                const lsn = std.fmt.parseInt(u32, lsn_str, 10) catch 0;
                @import("replication.zig").serve_replication_stream(server, stream, lsn) catch |err| {
                    std.debug.print("Replication stream error: {}\n", .{err});
                };
                return;
            }

            var parser = parser_mod.Parser.init(line, server.allocator);
            const stmt = parser.parse_statement() catch |err| {
                writer.interface.print("ERR PARSER: {}\n", .{err}) catch break;
                writer.interface.flush() catch break;
                continue;
            };

            defer {
                if (stmt == .create_table) {
                    server.allocator.free(stmt.create_table.columns);
                } else if (stmt == .insert) {
                    server.allocator.free(stmt.insert.values);
                }
            }

            var requires_exclusive_lock = false;
            var requires_shared_lock = false;
            switch (stmt) {
                .create_table, .drop_table => requires_exclusive_lock = true,
                .insert, .delete, .update, .select => requires_shared_lock = true,
                else => {},
            }

            if (server.is_replica) {
                switch (stmt) {
                    .select => {}, // allowed
                    .begin, .commit, .rollback => {}, // allowed, though effectively read-only txn
                    else => {
                        writer.interface.writeAll("ERR cannot write to a read-only replica\n") catch break;
                        writer.interface.flush() catch break;
                        continue;
                    },
                }
            }

            var did_lock_exclusive_now = false;
            var did_lock_shared_now = false;
            if (!in_transaction) {
                if (requires_exclusive_lock) {
                    server.active_txn_rwlock.lockUncancelable(server.io);
                    did_lock_exclusive_now = true;
                    txn_ctx = server.start_txn();
                    if (server.catalog.buffer_manager.log_manager) |lm| {
                        txn_ctx.?.prev_lsn = lm.append_record(txn_ctx.?.txn_id, 0, .begin, 0, 0, &[_]u8{}) catch 0;
                    }
                } else if (requires_shared_lock) {
                    server.active_txn_rwlock.lockSharedUncancelable(server.io);
                    did_lock_shared_now = true;
                    txn_ctx = server.start_txn();
                    if (server.catalog.buffer_manager.log_manager) |lm| {
                        txn_ctx.?.prev_lsn = lm.append_record(txn_ctx.?.txn_id, 0, .begin, 0, 0, &[_]u8{}) catch 0;
                    }
                }
            }

            if (stmt == .begin) {
                if (in_transaction) {
                    writer.interface.writeAll("ERR already in transaction\n") catch break;
                    writer.interface.flush() catch break;
                    continue;
                }
                server.active_txn_rwlock.lockSharedUncancelable(server.io);
                in_transaction = true;
                txn_ctx = server.start_txn();
                if (server.catalog.buffer_manager.log_manager) |lm| {
                    txn_ctx.?.prev_lsn = lm.append_record(txn_ctx.?.txn_id, 0, .begin, 0, 0, &[_]u8{}) catch 0;
                }
                writer.interface.writeAll("OK\n") catch break;
                writer.interface.flush() catch break;
                continue;
            } else if (stmt == .commit) {
                if (in_transaction) {
                    if (server.catalog.buffer_manager.log_manager) |lm| {
                        const lsn = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .commit, 0, 0, &[_]u8{}) catch 0;
                        lm.flush(lsn) catch {};
                    }
                    undo.clear_undo_stack(&undo_stack, server.allocator);
                    server.lock_manager.unlock_all(txn_ctx.?.txn_id);
                    if (txn_ctx) |*ctx| server.end_txn(ctx);
                    in_transaction = false;
                    txn_ctx = null;
                    server.active_txn_rwlock.unlockShared(server.io);
                }
                writer.interface.writeAll("OK\n") catch break;
                writer.interface.flush() catch break;
                continue;
            } else if (stmt == .rollback) {
                if (in_transaction) {
                    undo.execute_undo_stack(&undo_stack, server.catalog);
                    if (server.catalog.buffer_manager.log_manager) |lm| {
                        _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .abort, 0, 0, &[_]u8{}) catch 0;
                    }
                    undo.clear_undo_stack(&undo_stack, server.allocator);
                    server.lock_manager.unlock_all(txn_ctx.?.txn_id);
                    if (txn_ctx) |*ctx| server.end_txn(ctx);
                    in_transaction = false;
                    txn_ctx = null;
                    server.active_txn_rwlock.unlockShared(server.io);
                }
                writer.interface.writeAll("OK\n") catch break;
                writer.interface.flush() catch break;
                continue;
            }

            var ctx_ptr: ?*transaction.TransactionContext = null;
            if (txn_ctx) |*ctx| {
                ctx_ptr = ctx;
            }

            execution.execute_statement(server.allocator, server.catalog, stmt, ctx_ptr, &writer.interface, if (in_transaction or did_lock_exclusive_now or did_lock_shared_now) &undo_stack else null) catch |err| {
                if (did_lock_exclusive_now) {
                    if (server.catalog.buffer_manager.log_manager) |lm| {
                        _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .abort, 0, 0, &[_]u8{}) catch 0;
                    }
                    server.lock_manager.unlock_all(txn_ctx.?.txn_id);
                    if (txn_ctx) |*ctx| server.end_txn(ctx);
                    txn_ctx = null;
                    server.active_txn_rwlock.unlock(server.io);
                } else if (did_lock_shared_now) {
                    if (server.catalog.buffer_manager.log_manager) |lm| {
                        _ = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .abort, 0, 0, &[_]u8{}) catch 0;
                    }
                    server.lock_manager.unlock_all(txn_ctx.?.txn_id);
                    if (txn_ctx) |*ctx| server.end_txn(ctx);
                    txn_ctx = null;
                    server.active_txn_rwlock.unlockShared(server.io);
                }
                writer.interface.print("ERR EXEC: {}\n", .{err}) catch break;
                writer.interface.flush() catch break;
                continue;
            };

            if (did_lock_exclusive_now) {
                if (server.catalog.buffer_manager.log_manager) |lm| {
                    const lsn = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .commit, 0, 0, &[_]u8{}) catch 0;
                    lm.flush(lsn) catch {};
                }
                undo.clear_undo_stack(&undo_stack, server.allocator);
                server.lock_manager.unlock_all(txn_ctx.?.txn_id);
                if (txn_ctx) |*ctx| server.end_txn(ctx);
                txn_ctx = null;
                server.active_txn_rwlock.unlock(server.io);
            } else if (did_lock_shared_now) {
                if (server.catalog.buffer_manager.log_manager) |lm| {
                    const lsn = lm.append_record(txn_ctx.?.txn_id, txn_ctx.?.prev_lsn, .commit, 0, 0, &[_]u8{}) catch 0;
                    lm.flush(lsn) catch {};
                }
                undo.clear_undo_stack(&undo_stack, server.allocator);
                server.lock_manager.unlock_all(txn_ctx.?.txn_id);
                if (txn_ctx) |*ctx| server.end_txn(ctx);
                txn_ctx = null;
                server.active_txn_rwlock.unlockShared(server.io);
            }

            writer.interface.writeAll("OK\n") catch break;
            writer.interface.flush() catch break;
        }
    }
}
