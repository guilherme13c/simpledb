const std = @import("std");
const ast = @import("../ast.zig");
const Executor = @import("../executor.zig").Executor;
const free_tuple = @import("../executor.zig").free_tuple;

pub const LimitExecutor = struct {
    child: *Executor,
    limit: ?usize,
    offset: ?usize,
    count: usize = 0,
    skipped: usize = 0,
    allocator: std.mem.Allocator,

    pub fn open(self: *LimitExecutor) !void {
        self.count = 0;
        self.skipped = 0;
        try self.child.open();
    }

    pub fn next(self: *LimitExecutor) !?[]ast.Value {
        if (self.offset) |off| {
            while (self.skipped < off) {
                if (try self.child.next()) |tuple| {
                    free_tuple(self.allocator, tuple);
                    self.skipped += 1;
                } else {
                    return null;
                }
            }
        }

        if (self.limit) |lim| {
            if (self.count >= lim) {
                return null;
            }
        }

        if (try self.child.next()) |tuple| {
            self.count += 1;
            return tuple;
        }

        return null;
    }

    pub fn close(self: *LimitExecutor) void {
        self.child.close();
    }
};
