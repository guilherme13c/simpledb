const std = @import("std");
const ast = @import("../ast.zig");
const Executor = @import("../executor.zig").Executor;
const compare_values = @import("../executor.zig").compare_values;
const resolve_column = @import("../executor.zig").resolve_column;
const free_tuple = @import("../executor.zig").free_tuple;

pub const OrderByExecutor = struct {
    child: *Executor,
    order_by_exprs: []const ast.OrderByExpr,
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

            var indices = try self.allocator.alloc(usize, self.order_by_exprs.len);
            defer self.allocator.free(indices);
            
            for (self.order_by_exprs, 0..) |expr, i| {
                indices[i] = resolve_column(self.schema, expr.column) orelse return error.SchemaMismatch;
            }

            const SortContext = struct {
                exprs: []const ast.OrderByExpr,
                indices: []const usize,

                pub fn lessThan(ctx: @This(), a: []ast.Value, b: []ast.Value) bool {
                    for (ctx.exprs, 0..) |expr, i| {
                        const col_idx = ctx.indices[i];
                        if (a.len <= col_idx or b.len <= col_idx) return false;
                        const val_a = a[col_idx];
                        const val_b = b[col_idx];
                        
                        const eq = compare_values(val_a, .eq, val_b);
                        if (!eq) {
                            const lt = compare_values(val_a, .lt, val_b);
                            const gt = compare_values(val_a, .gt, val_b);
                            if (expr.is_desc) {
                                return gt;
                            } else {
                                return lt;
                            }
                        }
                    }
                    return false;
                }
            };

            std.mem.sort([]ast.Value, self.tuples.items, SortContext{ .exprs = self.order_by_exprs, .indices = indices }, SortContext.lessThan);
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
