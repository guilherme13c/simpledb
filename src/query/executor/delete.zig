const std = @import("std");
const ast = @import("../ast.zig");
const Table = @import("../../storage/table.zig").Table;
const Catalog = @import("../../storage/catalog.zig").Catalog;
const TransactionContext = @import("../../storage/wal/transaction.zig").TransactionContext;
const Executor = @import("../executor.zig").Executor;
const resolve_column = @import("../executor.zig").resolve_column;
const evaluate_expression = @import("../executor.zig").evaluate_expression;
const compare_values = @import("../executor.zig").compare_values;
const evaluate_join_expression = @import("../executor.zig").evaluate_join_expression;
const dupe_value = @import("../executor.zig").dupe_value;
const free_tuple = @import("../executor.zig").free_tuple;
const ValueContext = @import("../executor.zig").ValueContext;

// ─── Delete ──────────────────────────────────────────────────────────────────

/// DeleteExecutor implements the execution logic for the DeleteExecutor operator.
pub const DeleteExecutor = struct {
    table: *Table,
    condition: ast.Condition,
    txn_ctx: ?*TransactionContext,
    allocator: std.mem.Allocator,
    executed: bool = false,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *DeleteExecutor) !void {
        self.executed = false;
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *DeleteExecutor) !?[]ast.Value {
        if (self.executed) return null;

        switch (self.condition) {
            .eq => |eq| {
                try self.table.delete(self.txn_ctx, eq.key);
            },
            .range => |r| {
                const rids = try self.table.btree.scan(self.allocator, r.start, r.end);
                defer self.allocator.free(rids);
                // Each RID encodes a key – but we actually need the keys.
                // For now, range delete via sequential key deletion:
                var keys_buf: [256]u64 = undefined;
                var key_count: usize = 0;
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
                                if (key_count < keys_buf.len) {
                                    keys_buf[key_count] = key;
                                    key_count += 1;
                                }
                            }
                        }
                    }
                }
                for (keys_buf[0..key_count]) |key| {
                    try self.table.delete(self.txn_ctx, key);
                }
            },
        }

        self.executed = true;
        return null;
    }
};