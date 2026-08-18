const std = @import("std");
const ast = @import("../ast.zig");
const Table = @import("../../storage/table.zig").Table;
const Catalog = @import("../../storage/catalog.zig").Catalog;
const TransactionContext = @import("../../storage/wal/transaction.zig").TransactionContext;
const Executor = @import("../executor.zig").Executor;
const resolve_column = @import("../executor.zig").resolve_column;

pub const UpdateExecutor = struct {
    table: *Table,
    condition: ast.Condition,
    index_btree: ?*@import("../../storage/index/btree.zig").BTree = null,
    column_name: []const u8,
    new_value: ast.Value,
    txn_ctx: ?*TransactionContext = null,
    allocator: std.mem.Allocator,
    executed: bool = false,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *UpdateExecutor) !void {
        self.executed = false;
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *UpdateExecutor) !?[]ast.Value {
        if (self.executed) return null;
        
        const btree = if (self.index_btree) |idx| idx else self.table.btree;
        const col_idx = resolve_column(self.table.schema, self.column_name) orelse return error.SchemaMismatch;

        // Collect all keys to update
        var keys_buf = std.ArrayListUnmanaged(u64).empty;
        defer keys_buf.deinit(self.allocator);

        switch (self.condition) {
            .eq => |eq| {
                if (try btree.search(eq.key)) |_| {
                    try keys_buf.append(self.allocator, eq.key);
                }
            },
            .range => |r| {
                const rids = try btree.scan(self.allocator, r.start, r.end);
                defer self.allocator.free(rids);

                for (rids) |rid| {
                    const heap_page_id: u32 = @intCast(rid >> 32);
                    const slot_id: u16 = @intCast(rid & 0xFFFF);
                    const frame = try self.table.buffer_manager.fetch_frame(heap_page_id);
                    defer self.table.buffer_manager.unpin_frame(frame, false);
                    var view = @import("../../storage/page/slotted_view.zig").SlottedView.init(&frame.page, false);
                    if (view.get_tuple(slot_id)) |full_data| {
                        if (self.table.schema.len > 0 and full_data.len >= 16) {
                            const xmin = std.mem.readInt(u32, full_data[0..4][0..4], .little);
                            const xmax = std.mem.readInt(u32, full_data[4..8][0..4], .little);
                            
                            var is_visible = true;
                            if (self.txn_ctx) |ctx| {
                                is_visible = ctx.is_visible(xmin, xmax);
                            } else {
                                is_visible = (xmax == 0);
                            }
                            
                            if (is_visible) {
                                const key = std.mem.readInt(u64, full_data[8..16][0..8], .little);
                                try keys_buf.append(self.allocator, key);
                            }
                        }
                    }
                }
            },
        }

        // Apply updates
        for (keys_buf.items) |key| {
            if (try self.table.search(self.allocator, self.txn_ctx, key)) |raw_data| {
                defer self.allocator.free(raw_data);
                
                var tuple = try self.table.deserialize_tuple(self.allocator, raw_data);
                defer self.allocator.free(tuple);
                
                if (tuple[col_idx] == .varchar) self.allocator.free(tuple[col_idx].varchar);
                if (tuple[col_idx] == .json) self.allocator.free(tuple[col_idx].json);
                
                tuple[col_idx] = self.new_value;

                const new_data = try self.table.serialize_tuple(self.allocator, tuple);
                defer self.allocator.free(new_data);

                try self.table.delete(self.txn_ctx, key);
                const new_key = tuple[0].int;
                _ = try self.table.insert(self.txn_ctx, new_key, new_data);
                
                // Clean up old tuple strings
                for (tuple, 0..) |v, i| {
                    if (i == col_idx) continue;
                    if (v == .varchar) self.allocator.free(v.varchar);
                    if (v == .json) self.allocator.free(v.json);
                }
            }
        }

        self.executed = true;
        return null;
    }

    pub fn close(self: *UpdateExecutor) void {
        _ = self;
    }
};
