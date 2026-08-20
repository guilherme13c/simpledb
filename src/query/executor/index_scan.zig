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

// ─── IndexScan ───────────────────────────────────────────────────────────────

/// IndexScanExecutor implements the execution logic for the IndexScanExecutor operator.
pub const IndexScanExecutor = struct {
    table: *Table,
    condition: ast.Condition,
    allocator: std.mem.Allocator,
    txn_ctx: ?*TransactionContext = null,
    index_def: ?@import("../../storage/table.zig").IndexDef = null,
    rids: []u64 = &[_]u64{},
    current_idx: usize = 0,

    /// Initializes the executor and prepares it to yield tuples.
    pub fn open(self: *IndexScanExecutor) !void {
        if (self.index_def) |idx_def| {
            if (idx_def.index_type == .hash) {
                switch (self.condition) {
                    .eq => |eq| {
                        self.rids = try idx_def.hash_idx.?.search(self.allocator, eq.key);
                    },
                    .range => return error.RangeScanNotSupportedOnHashIndex,
                }
            } else {
                switch (self.condition) {
                    .eq => |eq| {
                        self.rids = try idx_def.btree.?.scan(self.allocator, eq.key, eq.key);
                    },
                    .range => |r| {
                        self.rids = try idx_def.btree.?.scan(self.allocator, r.start, r.end);
                    },
                }
            }
        } else {
            const btree = self.table.btree;
            switch (self.condition) {
                .eq => |eq| {
                    self.rids = try btree.scan(self.allocator, eq.key, eq.key);
                },
                .range => |r| {
                    self.rids = try btree.scan(self.allocator, r.start, r.end);
                },
            }
        }
        self.current_idx = 0;
    }

    /// Cleans up any resources or state allocated by the executor.
    pub fn close(self: *IndexScanExecutor) void {
        if (self.rids.len > 0) {
            self.allocator.free(self.rids);
            self.rids = &[_]u64{};
        }
    }

    /// Retrieves the next tuple from the executor. Returns null if no more tuples.
    pub fn next(self: *IndexScanExecutor) !?[]ast.Value {
        while (self.current_idx < self.rids.len) {
            const rid = self.rids[self.current_idx];
            self.current_idx += 1;

            if (self.txn_ctx) |ctx| {
                try ctx.lock_row_shared(self.table.btree.root_page_id, rid);
            }

            const heap_page_id: u32 = @intCast(rid >> 32);
            const slot_id: u16 = @intCast(rid & 0xFFFF);

            const frame = try self.table.buffer_manager.fetch_frame(heap_page_id);
            defer self.table.buffer_manager.unpin_frame(frame, false);

            var view = @import("../../storage/page/slotted_view.zig").SlottedView.init(&frame.page, false);
            if (view.get_tuple(slot_id)) |full_data| {
                if (full_data.len >= 8) {
                    const xmin = std.mem.readInt(u32, full_data[0..4][0..4], .little);
                    const xmax = std.mem.readInt(u32, full_data[4..8][0..4], .little);
                    
                    var is_visible = true;
                    if (self.txn_ctx) |ctx| {
                        is_visible = ctx.is_visible(xmin, xmax);
                    } else {
                        is_visible = (xmax == 0);
                    }
                    
                    if (is_visible) {
                        const data = full_data[8..];
                        if (self.table.schema.len > 0) {
                            return try self.table.deserialize_tuple(self.allocator, data);
                        } else {
                            var tuple = try self.allocator.alloc(ast.Value, 1);
                            tuple[0] = .{ .varchar = try self.allocator.dupe(u8, data) };
                            return tuple;
                        }
                    }
                }
            }
        }
        return null;
    }
};

