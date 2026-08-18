const std = @import("std");
const ast = @import("../ast.zig");
const Executor = @import("../executor.zig").Executor;
const compare_values = @import("../executor.zig").compare_values;
const resolve_column = @import("../executor.zig").resolve_column;
const free_tuple = @import("../executor.zig").free_tuple;

pub const OrderByExecutor = struct {
    child: *Executor,
    order_by_col: []const u8,
    is_desc: bool,
    schema: []const ast.ColumnDef,
    allocator: std.mem.Allocator,
    
    tuples: std.ArrayList([]ast.Value) = undefined,
    current_idx: usize = 0,
    executed: bool = false,

    pub fn open(self: *OrderByExecutor) !void {
        self.tuples = std.ArrayList([]ast.Value).empty;
        self.current_idx = 0;
        self.executed = false;
        try self.child.open();
    }

    pub fn next(self: *OrderByExecutor) !?[]ast.Value {
        if (!self.executed) {
            while (try self.child.next()) |tuple| {
                try self.tuples.append(self.allocator, tuple);
            }
            self.executed = true;

            const col_idx = resolve_column(self.schema, self.order_by_col) orelse return error.SchemaMismatch;

            const SortContext = struct {
                col_idx: usize,
                is_desc: bool,

                pub fn lessThan(ctx: @This(), a: []ast.Value, b: []ast.Value) bool {
                    if (a.len <= ctx.col_idx or b.len <= ctx.col_idx) return false;
                    const val_a = a[ctx.col_idx];
                    const val_b = b[ctx.col_idx];
                    const lt = compare_values(val_a, .lt, val_b);
                    const gt = compare_values(val_a, .gt, val_b);
                    
                    if (ctx.is_desc) {
                        return gt;
                    } else {
                        return lt;
                    }
                }
            };

            std.mem.sort([]ast.Value, self.tuples.items, SortContext{ .col_idx = col_idx, .is_desc = self.is_desc }, SortContext.lessThan);
        }

        if (self.current_idx < self.tuples.items.len) {
            const tuple = self.tuples.items[self.current_idx];
            self.current_idx += 1;
            return tuple;
        }

        return null;
    }

    pub fn close(self: *OrderByExecutor) void {
        for (self.tuples.items[self.current_idx..]) |tuple| {
            free_tuple(self.allocator, tuple);
        }
        self.tuples.deinit(self.allocator);
        self.child.close();
    }
};
