// src/threading.zig
const std = @import("std");

/// Global flag to enable deterministic scheduling.
pub var useDeterministic = false;

/// Queue of tasks when deterministic mode is active.
var taskQueue: ?*std.ArrayList(Task) = null;

const Task = struct {
    func: anytype,
    args: anytype,
};

/// Initialize the deterministic scheduler. Must be called before any spawning when
/// `useDeterministic` is true.
pub fn initDeterministic(alloc: *std.mem.Allocator) !void {
    if (taskQueue) |*q| return; // already initialized
    const q = try alloc.create(std.ArrayList(Task));
    q.* = std.ArrayList(Task).init(alloc);
    taskQueue = q;
}

/// Run all queued tasks sequentially. Clears the queue afterwards.
pub fn runAll() void {
    const q = taskQueue orelse return;
    var i: usize = 0;
    while (i < q.items.len) : (i += 1) {
        const t = q.items[i];
        // The function signature matches the stored args tuple.
        t.func(t.args);
    }
    q.clearRetainingCapacity();
}

/// Wrapper that either spawns a real thread (default) or queues the task when
/// deterministic mode is enabled.
pub fn spawnDetach(comptime func: anytype, args: anytype) void {
    if (useDeterministic) {
        // Queue the task for later execution.
        const q = taskQueue orelse return;
        // Store a copy of the args; they must be comptime-known or heap allocated.
        q.append(Task{ .func = func, .args = args }) catch return;
        return;
    }
    const t = std.Thread.spawn(.{}, func, args) catch return;
    t.detach();
}
