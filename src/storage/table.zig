const std = @import("std");
const BufferManager = @import("buffer_manager/buffer_manager.zig").BufferManager;
const BTree = @import("index/btree.zig").BTree;
const SlottedView = @import("page/slotted_view.zig").SlottedView;
const page = @import("page/page.zig");
const TransactionContext = @import("wal/transaction.zig").TransactionContext;

pub const IndexDef = struct {
    column_idx: usize,
    index_type: @import("../query/ast.zig").IndexType,
    btree: ?*BTree,
    hash_idx: ?*@import("index/hash_index.zig").HashIndex,
};

pub const Table = struct {
    btree: *BTree,
    buffer_manager: *BufferManager,
    current_heap_page_id: u32,
    next_alloc_page_id: *u32,
    schema: []const @import("../query/ast.zig").ColumnDef,
    allocator: std.mem.Allocator,
    indexes: std.StringHashMap(IndexDef),
    num_tuples: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, buffer_manager: *BufferManager, btree: *BTree, next_page_counter: *u32, schema: []const @import("../query/ast.zig").ColumnDef) !Table {
        const start_page_id = next_page_counter.*;
        next_page_counter.* += 1;

        const start_frame = try buffer_manager.new_frame(start_page_id);
        buffer_manager.unpin_frame(start_frame, true);

        return .{
            .btree = btree,
            .buffer_manager = buffer_manager,
            .current_heap_page_id = start_page_id,
            .next_alloc_page_id = next_page_counter,
            .schema = schema,
            .allocator = allocator,
            .indexes = std.StringHashMap(IndexDef).init(allocator),
            .num_tuples = std.atomic.Value(u64).init(0),
        };
    }

    pub fn insert(self: *Table, txn_ctx: ?*TransactionContext, key: u64, data: []const u8) !u64 {
        var mvcc_header: [8]u8 = undefined;
        const xmin = if (txn_ctx) |ctx| ctx.txn_id else 0;
        std.mem.writeInt(u32, mvcc_header[0..4][0..4], xmin, .little);
        std.mem.writeInt(u32, mvcc_header[4..8][0..4], 0, .little); // xmax = 0
        
        while (true) {
            const frame = try self.buffer_manager.fetch_frame(self.current_heap_page_id);

            const is_new = (frame.page.header.upper == 0 and frame.page.header.lower == 0);
            var view = SlottedView.init(&frame.page, is_new);

            if (view.insert_tuple(&mvcc_header, data)) |slot_id| {
                if (self.buffer_manager.log_manager) |lm| {
                    if (txn_ctx) |ctx| {
                        const lsn = try lm.append_record(ctx.txn_id, ctx.prev_lsn, .insert_tuple, self.current_heap_page_id, slot_id, data);
                        frame.page.header.lsn = lsn;
                        ctx.prev_lsn = lsn;
                    }
                }
                const rid = (@as(u64, self.current_heap_page_id) << 32) | @as(u64, slot_id);
                if (txn_ctx) |ctx| {
                    try ctx.lock_row_exclusive(self.btree.root_page_id, rid);
                }
                try self.btree.insert(txn_ctx, key, rid);
                
                if (self.indexes.count() > 0 and self.schema.len > 0) {
                    var it = self.indexes.iterator();
                    while (it.next()) |kv| {
                        const index_def = kv.value_ptr.*;
                        if (self.extract_hash_key(data, index_def.column_idx)) |hash_key| {
                            if (index_def.index_type == .btree) {
                                try index_def.btree.?.insert(txn_ctx, hash_key, rid);
                            } else if (index_def.index_type == .hash) {
                                try index_def.hash_idx.?.insert(hash_key, rid);
                            }
                        } else |_| {}
                    }
                }
                
                self.buffer_manager.unpin_frame(frame, true);
                _ = self.num_tuples.fetchAdd(1, .monotonic);
                return rid;
            } else |err| {
                self.buffer_manager.unpin_frame(frame, false);
                if (err == error.OutOfSpace) {
                    const id = self.next_alloc_page_id.*;
                    self.next_alloc_page_id.* += 1;

                    const new_heap_frame = try self.buffer_manager.new_frame(id);
                    self.buffer_manager.unpin_frame(new_heap_frame, true);

                    self.current_heap_page_id = id;
                } else {
                    return err;
                }
            }
        }
    }

    pub fn search(self: *Table, allocator: std.mem.Allocator, txn_ctx: ?*TransactionContext, key: u64) !?[]u8 {
        const rids = try self.btree.scan(allocator, key, key);
        defer allocator.free(rids);
        
        for (rids) |rid| {
            const heap_page_id: u32 = @intCast(rid >> 32);
            const slot_id: u16 = @intCast(rid & 0xFFFF);

            const frame = try self.buffer_manager.fetch_frame(heap_page_id);
            defer self.buffer_manager.unpin_frame(frame, false);

            var view = SlottedView.init(&frame.page, false);
            if (view.get_tuple(slot_id)) |full_data| {
                if (full_data.len < 8) continue;
                const xmin = std.mem.readInt(u32, full_data[0..4][0..4], .little);
                const xmax = std.mem.readInt(u32, full_data[4..8][0..4], .little);
                
                var is_visible = true;
                if (txn_ctx) |ctx| {
                    is_visible = ctx.is_visible(xmin, xmax);
                } else {
                    is_visible = (xmax == 0);
                }

                if (is_visible) {
                    const data = full_data[8..];
                    const copy = try allocator.alloc(u8, data.len);
                    @memcpy(copy, data);
                    return copy;
                }
            }
        }
        return null;
    }

    pub fn extract_hash_key(self: *Table, data: []const u8, col_idx: usize) !u64 {
        const tuple = try self.deserialize_tuple(self.allocator, data);
        defer {
            for (tuple) |v| if (v == .varchar) self.allocator.free(v.varchar);
            self.allocator.free(tuple);
        }
        const val = tuple[col_idx];
        return switch (val) {
            .int => |v| v,
            .varchar => |s| std.hash.Wyhash.hash(0, s),
            .bool => |b| @as(u64, if (b) 1 else 0),
            .float => |f| @as(u64, @bitCast(f)),
            .signed_int => |i| @as(u64, @bitCast(i)),
            else => 0,
        };
    }

    pub fn scan(self: *Table, allocator: std.mem.Allocator, txn_ctx: ?*TransactionContext, start_key: u64, end_key: u64) ![][]u8 {
        const rids = try self.btree.scan(allocator, start_key, end_key);
        defer allocator.free(rids);

        var results = std.ArrayList([]u8).empty;

        for (rids) |rid| {
            const heap_page_id: u32 = @intCast(rid >> 32);
            const slot_id: u16 = @intCast(rid & 0xFFFF);

            const frame = try self.buffer_manager.fetch_frame(heap_page_id);
            var view = SlottedView.init(&frame.page, false);
            
            if (view.get_tuple(slot_id)) |full_data| {
                if (full_data.len >= 8) {
                    const xmin = std.mem.readInt(u32, full_data[0..4][0..4], .little);
                    const xmax = std.mem.readInt(u32, full_data[4..8][0..4], .little);
                    
                    var is_visible = true;
                    if (txn_ctx) |ctx| {
                        is_visible = ctx.is_visible(xmin, xmax);
                    } else {
                        is_visible = (xmax == 0);
                    }
                    
                    if (is_visible) {
                        const data = full_data[8..];
                        const copy = try allocator.alloc(u8, data.len);
                        @memcpy(copy, data);
                        try results.append(allocator, copy);
                    }
                }
            }
            
            self.buffer_manager.unpin_frame(frame, false);
        }

        return results.toOwnedSlice(allocator);
    }

    pub fn delete(self: *Table, txn_ctx: ?*TransactionContext, key: u64) !void {
        const rids = try self.btree.scan(self.allocator, key, key);
        defer self.allocator.free(rids);
        
        for (rids) |rid| {
            const heap_page_id: u32 = @intCast(rid >> 32);
            const slot_id: u16 = @intCast(rid & 0xFFFF);
            
            const frame = try self.buffer_manager.fetch_frame(heap_page_id);
            var view = SlottedView.init(&frame.page, false);
            
            if (view.get_tuple(slot_id)) |full_data| {
                if (full_data.len >= 8) {
                    const xmin = std.mem.readInt(u32, full_data[0..4][0..4], .little);
                    const xmax = std.mem.readInt(u32, full_data[4..8][0..4], .little);
                    
                    var is_visible = true;
                    if (txn_ctx) |ctx| {
                        is_visible = ctx.is_visible(xmin, xmax);
                    } else {
                        is_visible = (xmax == 0);
                    }
                    
                    if (is_visible) {
                        if (txn_ctx) |ctx| {
                            try ctx.lock_row_exclusive(self.btree.root_page_id, rid);
                            
                            if (xmax != 0 and xmax != ctx.txn_id) {
                                self.buffer_manager.unpin_frame(frame, false);
                                return error.SerializationFailure;
                            }
                            
                            try view.update_xmax(slot_id, ctx.txn_id);
                            
                            if (self.buffer_manager.log_manager) |lm| {
                                const lsn = try lm.append_record(ctx.txn_id, ctx.prev_lsn, .delete_tuple, heap_page_id, slot_id, &[_]u8{});
                                frame.page.header.lsn = lsn;
                                ctx.prev_lsn = lsn;
                            }
                            self.buffer_manager.unpin_frame(frame, true);
                        } else {
                            try view.update_xmax(slot_id, std.math.maxInt(u32));
                            self.buffer_manager.unpin_frame(frame, true);
                        }
                        _ = self.num_tuples.fetchSub(1, .monotonic);
                        return; // Successfully deleted the visible tuple
                    }
                }
            }
            self.buffer_manager.unpin_frame(frame, false);
        }
    }

    pub fn serialize_tuple(self: *Table, allocator: std.mem.Allocator, values: []const @import("../query/ast.zig").Value) ![]u8 {
        if (values.len != self.schema.len) return error.SchemaMismatch;
        var total_size: usize = 0;
        for (values) |v| {
            switch (v) {
                .int => total_size += 8,
                .bool => total_size += 1,
                .varchar => |s| total_size += 4 + s.len,
                .float => total_size += 8,
                .timestamp => total_size += 8,
                .json => |s| total_size += 4 + s.len,
                .uuid => total_size += 16,
                .signed_int => total_size += 8,
                .null_val => return error.NullsNotSupported,
            }
        }
        var buf = try allocator.alloc(u8, total_size);
        var offset: usize = 0;
        for (values) |v| {
            switch (v) {
                .int => |i| {
                    std.mem.writeInt(u64, buf[offset..offset+8][0..8], i, .little);
                    offset += 8;
                },
                .bool => |b| {
                    buf[offset] = if (b) 1 else 0;
                    offset += 1;
                },
                .null_val => return error.NullsNotSupported,
                .varchar => |s| {
                    std.mem.writeInt(u32, buf[offset..offset+4][0..4], @intCast(s.len), .little);
                    offset += 4;
                    std.mem.copyForwards(u8, buf[offset..], s);
                    offset += s.len;
                },
                .float => |f| {
                    std.mem.writeInt(u64, buf[offset..offset+8][0..8], @bitCast(f), .little);
                    offset += 8;
                },
                .timestamp => |t| {
                    std.mem.writeInt(u64, buf[offset..offset+8][0..8], @bitCast(t), .little);
                    offset += 8;
                },
                .json => |s| {
                    std.mem.writeInt(u32, buf[offset..offset+4][0..4], @intCast(s.len), .little);
                    offset += 4;
                    std.mem.copyForwards(u8, buf[offset..], s);
                    offset += s.len;
                },
                .uuid => |u| {
                    std.mem.copyForwards(u8, buf[offset..], &u);
                    offset += 16;
                },
                .signed_int => |i| {
                    std.mem.writeInt(u64, buf[offset..offset+8][0..8], @bitCast(i), .little);
                    offset += 8;
                },
            }
        }
        return buf;
    }

    pub fn deserialize_tuple(self: *Table, allocator: std.mem.Allocator, data: []const u8) ![]@import("../query/ast.zig").Value {
        var values = try allocator.alloc(@import("../query/ast.zig").Value, self.schema.len);
        var offset: usize = 0;
        for (self.schema, 0..) |col, i| {
            if (offset >= data.len) {
                switch (col.data_type) {
                    .int => values[i] = .{ .int = 0 },
                    .bool => values[i] = .{ .bool = false },
                    .varchar => values[i] = .{ .varchar = try allocator.dupe(u8, "") },
                    .float => values[i] = .{ .float = 0.0 },
                    .timestamp => values[i] = .{ .timestamp = 0 },
                    .json => values[i] = .{ .json = try allocator.dupe(u8, "{}") },
                    .uuid => values[i] = .{ .uuid = [_]u8{0} ** 16 },
                    .signed_int => values[i] = .{ .signed_int = 0 },
                }
                continue;
            }
            switch (col.data_type) {
                .int => {
                    values[i] = .{ .int = std.mem.readInt(u64, data[offset..offset+8][0..8], .little) };
                    offset += 8;
                },
                .bool => {
                    values[i] = .{ .bool = data[offset] == 1 };
                    offset += 1;
                },
                .varchar => {
                    const len = std.mem.readInt(u32, data[offset..offset+4][0..4], .little);
                    offset += 4;
                    const str = data[offset..offset+len];
                    offset += len;
                    values[i] = .{ .varchar = try allocator.dupe(u8, str) };
                },
                .float => {
                    const bits = std.mem.readInt(u64, data[offset..offset+8][0..8], .little);
                    values[i] = .{ .float = @bitCast(bits) };
                    offset += 8;
                },
                .timestamp => {
                    const bits = std.mem.readInt(u64, data[offset..offset+8][0..8], .little);
                    values[i] = .{ .timestamp = @bitCast(bits) };
                    offset += 8;
                },
                .json => {
                    const len = std.mem.readInt(u32, data[offset..offset+4][0..4], .little);
                    offset += 4;
                    const str = data[offset..offset+len];
                    offset += len;
                    values[i] = .{ .json = try allocator.dupe(u8, str) };
                },
                .uuid => {
                    var uuid: [16]u8 = undefined;
                    std.mem.copyForwards(u8, &uuid, data[offset..offset+16]);
                    values[i] = .{ .uuid = uuid };
                    offset += 16;
                },
                .signed_int => {
                    const bits = std.mem.readInt(u64, data[offset..offset+8][0..8], .little);
                    values[i] = .{ .signed_int = @bitCast(bits) };
                    offset += 8;
                },
            }
        }
        return values;
    }
};
