const std = @import("std");
const ast = @import("../ast.zig");
const exec = @import("../executor.zig");
const Executor = exec.Executor;

pub const WindowExecutor = struct {
    child: *Executor,
    window_functions: []const ast.WindowFunctionExpr,
    input_schema: []const ast.ColumnDef,
    allocator: std.mem.Allocator,

    tuples: std.ArrayListUnmanaged([]ast.Value) = .empty,
    current_idx: usize = 0,
    
    pub fn open(self: *@This()) !void {
        try self.child.open();
        
        while (try self.child.next()) |child_tuple| {
            var new_tuple = try self.allocator.alloc(ast.Value, child_tuple.len + self.window_functions.len);
            @memcpy(new_tuple[0..child_tuple.len], child_tuple);
            for (0..self.window_functions.len) |i| {
                new_tuple[child_tuple.len + i] = .null_val;
            }
            try self.tuples.append(self.allocator, new_tuple);
        }
        
        for (self.window_functions, 0..) |wf, wf_idx| {
            const part_col_idx = if (wf.partition_by) |p| exec.resolve_column(self.input_schema, p) else null;
            const order_col_idx = if (wf.order_by) |o| exec.resolve_column(self.input_schema, o) else null;
            
            const SortCtx = struct {
                part_idx: ?usize,
                order_idx: ?usize,
                is_desc: bool,
                
                pub fn lessThan(ctx: @This(), lhs: []ast.Value, rhs: []ast.Value) bool {
                    if (ctx.part_idx) |p| {
                        if (exec.compare_values(lhs[p], .eq, rhs[p]) == false) {
                            return exec.compare_values(lhs[p], .lt, rhs[p]);
                        }
                    }
                    if (ctx.order_idx) |o| {
                        if (exec.compare_values(lhs[o], .eq, rhs[o]) == false) {
                            if (ctx.is_desc) {
                                return exec.compare_values(lhs[o], .gt, rhs[o]);
                            } else {
                                return exec.compare_values(lhs[o], .lt, rhs[o]);
                            }
                        }
                    }
                    return false;
                }
            };
            
            std.sort.block([]ast.Value, self.tuples.items, SortCtx{
                .part_idx = part_col_idx,
                .order_idx = order_col_idx,
                .is_desc = wf.is_desc,
            }, SortCtx.lessThan);
            
            var current_row_number: u64 = 1;
            var current_rank: u64 = 1;
            var current_sum: i64 = 0;
            
            for (self.tuples.items, 0..) |tuple, row_idx| {
                if (part_col_idx) |p| {
                    if (row_idx > 0) {
                        const prev_tuple = self.tuples.items[row_idx - 1];
                        if (!exec.compare_values(tuple[p], .eq, prev_tuple[p])) {
                            current_row_number = 1;
                            current_rank = 1;
                            current_sum = 0;
                        }
                    }
                }
                
                if (order_col_idx) |o| {
                    if (row_idx > 0) {
                        const prev_tuple = self.tuples.items[row_idx - 1];
                        if (!exec.compare_values(tuple[o], .eq, prev_tuple[o])) {
                            current_rank = current_row_number;
                        }
                    }
                } else {
                    current_rank = current_row_number;
                }
                
                const val_col_idx = self.input_schema.len + wf_idx;
                
                switch (wf.func) {
                    .row_number => tuple[val_col_idx] = .{ .int = current_row_number },
                    .rank => tuple[val_col_idx] = .{ .int = current_rank },
                    .count => tuple[val_col_idx] = .{ .int = current_row_number },
                    .sum => {
                        const arg_idx = exec.resolve_column(self.input_schema, wf.arg_column.?).?;
                        if (tuple[arg_idx] == .int) {
                            current_sum += @as(i64, @intCast(tuple[arg_idx].int));
                        } else if (tuple[arg_idx] == .signed_int) {
                            current_sum += tuple[arg_idx].signed_int;
                        }
                        tuple[val_col_idx] = .{ .signed_int = current_sum };
                    },
                }
                
                current_row_number += 1;
            }
        }
        
        self.current_idx = 0;
    }
    
    pub fn next(self: *@This()) !?[]ast.Value {
        if (self.current_idx >= self.tuples.items.len) return null;
        const res = self.tuples.items[self.current_idx];
        self.current_idx += 1;
        
        var duped = try self.allocator.alloc(ast.Value, res.len);
        for (res, 0..) |v, i| {
            duped[i] = try exec.dupe_value(self.allocator, v);
        }
        return duped;
    }
    
    pub fn close(self: *@This()) void {
        self.child.close();
        for (self.tuples.items) |t| {
            self.allocator.free(t);
        }
        self.tuples.deinit(self.allocator);
    }
    
    pub fn explain(self: *@This(), writer: anytype, depth: usize) !void {
        var indent_buf: [64]u8 = undefined;
        @memset(&indent_buf, ' ');
        const indent_len = @min(depth * 2, 64);
        const indent = indent_buf[0..indent_len];
        try writer.print("{s}-> WindowFunction\n", .{indent});
        try self.child.explain(writer, depth + 1);
    }
};
