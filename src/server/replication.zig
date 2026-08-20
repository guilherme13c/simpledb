const std = @import("std");
const server_mod = @import("server.zig");
const log_record = @import("../storage/wal/log_record.zig");
const LogRecordHeader = log_record.LogRecordHeader;
const LogRecordType = log_record.LogRecordType;
const Table = @import("../storage/table.zig").Table;

pub fn serve_replication_stream(server: *server_mod.Server, stream: std.Io.net.Stream, start_lsn: u32) !void {
    std.debug.print("Leader starting replication stream to follower from LSN {}\n", .{start_lsn});
    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(server.io, &write_buf);

    var current_lsn = start_lsn;
    var header_buf: [@sizeOf(LogRecordHeader)]u8 = undefined;

    const fd: i32 = stream.socket.handle;
    const t = std.Thread.spawn(.{}, read_acks_loop, .{ server, stream, fd }) catch return;
    t.detach();

    while (true) {
        if (server.catalog.buffer_manager.log_manager) |lm| {
            var bytes_read: usize = 0;
            // Read header
            while (bytes_read < header_buf.len) {
                // To avoid Zig's Io interface complexities, we just use std.fs.File read
                // Actually the log manager uses Io.File.
                // std.debug.print("[LeaderRepl] Reading header at lsn {d}\n", .{current_lsn});
                const read = lm.wal_file.readPositional(server.io, &[_][]u8{header_buf[bytes_read..]}, current_lsn + bytes_read) catch |err| {
                    if (err == error.EndOfStream) {
                        lm.mutex.lockUncancelable(server.io);
                        lm.cond.waitUncancelable(server.io, &lm.mutex);
                        lm.mutex.unlock(server.io);
                        break;
                    } else {
                        return err;
                    }
                };
                if (read == 0) {
                    lm.mutex.lockUncancelable(server.io);
                    lm.cond.waitUncancelable(server.io, &lm.mutex);
                    lm.mutex.unlock(server.io);
                    break;
                }
                bytes_read += read;
            }

            if (bytes_read == header_buf.len) {
                // We have a full header, send it!
                writer.interface.writeAll(&header_buf) catch return;
                const header = std.mem.bytesAsValue(LogRecordHeader, &header_buf);
                const payload_len = header.length - @sizeOf(LogRecordHeader);

                if (payload_len > 0) {
                    const payload_buf = try server.allocator.alloc(u8, payload_len);
                    defer server.allocator.free(payload_buf);

                    const p_read = try lm.wal_file.readPositional(server.io, &[_][]u8{payload_buf}, current_lsn + @sizeOf(LogRecordHeader));
                    if (p_read == payload_len) {
                        writer.interface.writeAll(payload_buf) catch return;
                    }
                }

                writer.interface.flush() catch return;
                current_lsn += header.length;
            }
        } else {
            // No log manager
            server.io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
        }
    }
}

pub fn connect_and_replicate(server: *server_mod.Server) !void {
    if (server.leader_address == null) return;

    var iter = std.mem.splitScalar(u8, server.leader_address.?, ':');
    const host = iter.next() orelse "127.0.0.1";
    const port_str = iter.next() orelse "8080";
    const port = try std.fmt.parseInt(u16, port_str, 10);

    std.debug.print("Replica connecting to leader at {s}:{d}\n", .{ host, port });

    const peer = try std.Io.net.IpAddress.parseIp4(host, port);
    const stream = try peer.connect(server.io, .{ .mode = .stream });
    defer stream.socket.close(server.io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(server.io, &write_buf);
    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(server.io, &read_buf);

    // Start from current LSN
    var start_lsn: u32 = 0;
    if (server.catalog.buffer_manager.log_manager) |lm| {
        start_lsn = lm.current_offset;
    }

    try writer.interface.print("START_REPLICATION {d}\r\n", .{start_lsn});
    try writer.interface.flush();

    var header_buf: [@sizeOf(LogRecordHeader)]u8 = undefined;

    while (true) {
        reader.interface.readSliceAll(&header_buf) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        const header = std.mem.bytesAsValue(LogRecordHeader, &header_buf);
        const payload_len = header.length - @sizeOf(LogRecordHeader);

        const payload_buf = try server.allocator.alloc(u8, payload_len);
        defer server.allocator.free(payload_buf);

        if (payload_len > 0) {
            try reader.interface.readSliceAll(payload_buf);
        }

        // Write to local WAL
        if (server.catalog.buffer_manager.log_manager) |lm| {
            lm.mutex.lockUncancelable(server.io);
            defer lm.mutex.unlock(server.io);

            _ = try lm.wal_file.writePositional(server.io, &[_][]const u8{&header_buf}, header.lsn);
            if (payload_len > 0) {
                _ = try lm.wal_file.writePositional(server.io, &[_][]const u8{payload_buf}, header.lsn + @sizeOf(LogRecordHeader));
            }
            lm.current_offset = header.lsn + header.length;
            lm.global_lsn.store(lm.current_offset, .release);
        }

        // Apply logical record to local state
        if (header.record_type == .logical_insert) {
            // Find table by root_page_id (header.page_id)
            if (find_table_by_root_page_id(server.catalog, header.page_id)) |table| {
                const key = std.mem.readInt(u64, payload_buf[0..8][0..8], .little);
                const data = payload_buf[8..];
                _ = try table.insert(null, key, data);
                if (header.page_id == 0) {
                    server.catalog.load_sys_tables() catch {};
                }
            }
        } else if (header.record_type == .logical_delete) {
            if (find_table_by_root_page_id(server.catalog, header.page_id)) |table| {
                const key = std.mem.readInt(u64, payload_buf[0..8][0..8], .little);
                try table.delete(null, key);
                if (header.page_id == 0) {
                    server.catalog.load_sys_tables() catch {};
                }
            }
        }
    }
}

fn find_table_by_root_page_id(catalog: *@import("../storage/catalog.zig").Catalog, root_page_id: u32) ?*Table {
    var it = catalog.tables.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.*.btree.root_page_id == root_page_id) {
            return kv.value_ptr.*;
        }
    }
    return null;
}

fn read_acks_loop(server: *server_mod.Server, stream: std.Io.net.Stream, fd: i32) void {
    while (true) {
        var line_buf: [256]u8 = undefined;
        var len: usize = 0;
        var end_of_stream = false;
        while (len < line_buf.len) {
            var b: [1]u8 = undefined;
            const r = std.posix.read(stream.socket.handle, &b) catch {
                end_of_stream = true;
                break;
            };
            if (r == 0) {
                end_of_stream = true;
                break;
            }
            line_buf[len] = b[0];
            len += 1;
            if (b[0] == '\n') break;
        }
        if (end_of_stream) break;
        const line = line_buf[0..len];
        if (std.mem.startsWith(u8, line, "ACK ")) {
            const lsn_str = std.mem.trim(u8, line[4..], " \n\r");
            if (std.fmt.parseInt(u32, lsn_str, 10)) |lsn| {
                std.debug.print("[Replication] Received ACK {d} from fd {d}\n", .{ lsn, fd });
                server.update_peer_lsn(fd, lsn);
            } else |_| {}
        }
    }
}
