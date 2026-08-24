const std = @import("std");

// Queue of tasks for deterministic mode (not used in current code)
var taskQueue: ?*std.ArrayList(Task) = null;

const Task = struct {
    func: *const anyopaque,
    args: *anyopaque,
};

pub fn initDeterministic(alloc: *std.mem.Allocator) !void {
    // Not needed for current code; kept for compatibility
    if (taskQueue) return;
    const q = try alloc.create(std.ArrayList(Task));
    q.* = std.ArrayList(Task).init(alloc);
    taskQueue = q;
}

pub fn runAll() void {
    // Not needed; tasks are executed via spawnDetach
    return;
}

pub fn spawnDetach(comptime func: anytype, args: anytype) void {
    // Directly spawn a thread; deterministic mode is disabled
    const t = std.Thread.spawn(.{}, func, args) catch return;
    t.detach();
}
