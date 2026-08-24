const std = @import("std");

pub const LockMode = enum {
    shared,
    exclusive,
};

const LockRequest = struct {
    txn_id: u32,
    mode: LockMode,
    granted: bool,
};

const LockQueue = struct {
    requests: std.ArrayList(LockRequest),
    cv: std.Io.Condition,

    pub fn init() LockQueue {
        return .{
            .requests = std.ArrayList(LockRequest).empty,
            .cv = .init,
        };
    }

    pub fn deinit(self: *LockQueue, allocator: std.mem.Allocator) void {
        self.requests.deinit(allocator);
    }
};

pub const LockManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    // Maps resource_id (e.g. hash of table + key) to its lock queue
    lock_table: std.AutoHashMap(u64, *LockQueue),

    // Maps txn_id to a list of resources they have locked (for fast release on abort/commit)
    txn_locks: std.AutoHashMap(u32, std.ArrayList(u64)),
    killed_txns: std.AutoHashMap(u32, void),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) LockManager {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .lock_table = std.AutoHashMap(u64, *LockQueue).init(allocator),
            .txn_locks = std.AutoHashMap(u32, std.ArrayList(u64)).init(allocator),
            .killed_txns = std.AutoHashMap(u32, void).init(allocator),
        };
    }

    pub fn deinit(self: *LockManager) void {
        var it = self.lock_table.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.lock_table.deinit();

        var txn_it = self.txn_locks.iterator();
        while (txn_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.txn_locks.deinit();
        self.killed_txns.deinit();
    }

    pub fn lock_shared(self: *LockManager, txn_id: u32, resource_id: u64) !void {
        self.mutex.lockUncancelable(self.io);

        var queue = try self.get_or_create_queue(resource_id);

        // Check if we already hold a lock on this resource
        for (queue.requests.items) |*req| {
            if (req.txn_id == txn_id) {
                if (req.granted) {
                    self.mutex.unlock(self.io);
                    return;
                }
            }
        }

        try queue.requests.append(self.allocator, .{ .txn_id = txn_id, .mode = .shared, .granted = false });
        try self.add_txn_lock(txn_id, resource_id);

        var attempts: usize = 0;
        while (!self.can_grant_lock(queue, txn_id, .shared)) {
            self.mutex.unlock(self.io);
            const timeout = std.Io.Timeout{
                .duration = .{
                    .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms },
                    .clock = .awake,
                },
            };
            timeout.sleep(self.io) catch {};
            attempts += 1;
            self.mutex.lockUncancelable(self.io);
            if (self.killed_txns.contains(txn_id)) {
                self.unlock_internal(txn_id, resource_id);
                self.mutex.unlock(self.io);
                return error.DeadlockDetected;
            }
            if (attempts > 100) {
                self.unlock_internal(txn_id, resource_id);
                if (self.txn_locks.getPtr(txn_id)) |list| {
                    var i: usize = 0;
                    while (i < list.items.len) {
                        if (list.items[i] == resource_id) {
                            _ = list.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                }
                self.mutex.unlock(self.io);
                return error.DeadlockDetected;
            }
        }

        // Grant the lock
        for (queue.requests.items) |*req| {
            if (req.txn_id == txn_id and !req.granted) {
                req.granted = true;
                break;
            }
        }
        self.mutex.unlock(self.io);
    }

    pub fn lock_exclusive(self: *LockManager, txn_id: u32, resource_id: u64) !void {
        self.mutex.lockUncancelable(self.io);

        var queue = try self.get_or_create_queue(resource_id);

        var existing_req_idx: ?usize = null;
        for (queue.requests.items, 0..) |*req, i| {
            if (req.txn_id == txn_id) {
                if (req.mode == .exclusive and req.granted) {
                    self.mutex.unlock(self.io);
                    return; // Already hold exclusive lock
                }
                existing_req_idx = i;
            }
        }

        if (existing_req_idx) |idx| {
            // Lock upgrade
            queue.requests.items[idx].mode = .exclusive;
            queue.requests.items[idx].granted = false;
        } else {
            try queue.requests.append(self.allocator, .{ .txn_id = txn_id, .mode = .exclusive, .granted = false });
            try self.add_txn_lock(txn_id, resource_id);
        }

        var attempts: usize = 0;
        while (!self.can_grant_lock(queue, txn_id, .exclusive)) {
            self.mutex.unlock(self.io);
            const timeout = std.Io.Timeout{
                .duration = .{
                    .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms },
                    .clock = .awake,
                },
            };
            timeout.sleep(self.io) catch {};
            attempts += 1;
            self.mutex.lockUncancelable(self.io);
            if (self.killed_txns.contains(txn_id)) {
                self.unlock_internal(txn_id, resource_id);
                self.mutex.unlock(self.io);
                return error.DeadlockDetected;
            }
            if (attempts > 100) {
                self.unlock_internal(txn_id, resource_id);
                if (self.txn_locks.getPtr(txn_id)) |list| {
                    var i: usize = 0;
                    while (i < list.items.len) {
                        if (list.items[i] == resource_id) {
                            _ = list.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                }
                self.mutex.unlock(self.io);
                return error.DeadlockDetected;
            }
        }

        // Grant the lock
        for (queue.requests.items) |*req| {
            if (req.txn_id == txn_id and !req.granted) {
                req.granted = true;
                break;
            }
        }
        self.mutex.unlock(self.io);
    }

    pub fn unlock(self: *LockManager, txn_id: u32, resource_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.unlock_internal(txn_id, resource_id);

        // Remove from txn_locks
        if (self.txn_locks.getPtr(txn_id)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == resource_id) {
                    _ = list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    pub fn unlock_all(self: *LockManager, txn_id: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.txn_locks.getPtr(txn_id)) |list| {
            for (list.items) |res_id| {
                self.unlock_internal(txn_id, res_id);
            }
            list.deinit(self.allocator);
            _ = self.txn_locks.remove(txn_id);
        }
    }

    pub fn kill_transaction(self: *LockManager, txn_id: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.killed_txns.put(txn_id, {}) catch {};

        var it = self.lock_table.valueIterator();
        while (it.next()) |queue| {
            queue.*.cv.broadcast(self.io);
        }
    }

    pub fn get_wait_for_edges(self: *LockManager, list: *std.ArrayList(@import("wfg.zig").Edge)) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.lock_table.valueIterator();
        while (it.next()) |queue_ptr| {
            const queue = queue_ptr.*;

            // Collect holders and waiters
            for (queue.requests.items) |req_wait| {
                if (!req_wait.granted) {
                    for (queue.requests.items) |req_hold| {
                        if (req_hold.granted and req_hold.txn_id != req_wait.txn_id) {
                            // wait -> hold
                            try list.append(self.allocator, .{ .waiting = req_wait.txn_id, .holding = req_hold.txn_id });
                        }
                    }
                }
            }
        }
    }

    fn unlock_internal(self: *LockManager, txn_id: u32, resource_id: u64) void {
        if (self.lock_table.getPtr(resource_id)) |queue_ptr| {
            const queue = queue_ptr.*;
            var i: usize = 0;
            while (i < queue.requests.items.len) {
                if (queue.requests.items[i].txn_id == txn_id) {
                    _ = queue.requests.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            queue.cv.broadcast(self.io); // Wake up other waiting transactions
        }
    }

    fn get_or_create_queue(self: *LockManager, resource_id: u64) !*LockQueue {
        const res = try self.lock_table.getOrPut(resource_id);
        if (!res.found_existing) {
            const queue = try self.allocator.create(LockQueue);
            queue.* = LockQueue.init();
            res.value_ptr.* = queue;
        }
        return res.value_ptr.*;
    }

    fn add_txn_lock(self: *LockManager, txn_id: u32, resource_id: u64) !void {
        const res = try self.txn_locks.getOrPut(txn_id);
        if (!res.found_existing) {
            res.value_ptr.* = std.ArrayList(u64).empty;
        }

        for (res.value_ptr.items) |existing_res| {
            if (existing_res == resource_id) return;
        }
        try res.value_ptr.append(self.allocator, resource_id);
    }

    fn can_grant_lock(self: *LockManager, queue: *LockQueue, txn_id: u32, mode: LockMode) bool {
        _ = self;
        var someone_else_has_exclusive = false;
        var shared_count: usize = 0;
        var self_has_req = false;
        var self_mode: LockMode = .shared;
        var self_granted = false;

        for (queue.requests.items) |req| {
            if (req.txn_id == txn_id) {
                self_has_req = true;
                self_mode = req.mode;
                self_granted = req.granted;
            } else {
                if (req.granted) {
                    if (req.mode == .exclusive) someone_else_has_exclusive = true;
                    if (req.mode == .shared) shared_count += 1;
                } else {
                    if (req.mode == .exclusive) someone_else_has_exclusive = true;
                }
            }
        }

        if (!self_has_req) {
            // New request from this txn
            if (mode == .shared) return !someone_else_has_exclusive;
            if (mode == .exclusive) return shared_count == 0 and !someone_else_has_exclusive;
            return false;
        }

        // Self request already exists in queue
        if (self_granted) {
            if (mode == .shared) return !someone_else_has_exclusive;
            if (mode == .exclusive) return shared_count == 0 and !someone_else_has_exclusive;
            return false;
        } else {
            // Ungranted request (upgrade or pending)
            if (self_mode == .exclusive and mode == .exclusive) {
                return shared_count == 0 and !someone_else_has_exclusive;
            }
            if (self_mode == .shared and mode == .exclusive) {
                return shared_count == 0 and !someone_else_has_exclusive;
            }
            if (mode == .shared) return !someone_else_has_exclusive;
            return false;
        }
    }
};

test "LockManager shared and exclusive" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var lm = LockManager.init(std.testing.allocator, io);
    defer lm.deinit();

    // T1 gets shared
    try lm.lock_shared(1, 42);
    // T2 gets shared
    try lm.lock_shared(2, 42);

    // T1 unlocks
    lm.unlock(1, 42);

    // T2 unlocks
    lm.unlock(2, 42);

    // T3 gets exclusive
    try lm.lock_exclusive(3, 42);

    // Unlock all for T3
    lm.unlock_all(3);
}

test "can_grant_lock: shared after shared grants" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var lm = LockManager.init(std.testing.allocator, io);
    defer lm.deinit();

    var queue = LockQueue.init();
    defer {
        queue.requests.deinit(std.testing.allocator);
    }
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 1, .mode = .shared, .granted = true });
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 2, .mode = .shared, .granted = false });

    try std.testing.expect(lm.can_grant_lock(&queue, 2, .shared));
}

test "can_grant_lock: exclusive after shared blocks" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var lm = LockManager.init(std.testing.allocator, io);
    defer lm.deinit();

    var queue = LockQueue.init();
    defer {
        queue.requests.deinit(std.testing.allocator);
    }
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 1, .mode = .shared, .granted = true });
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 2, .mode = .exclusive, .granted = false });

    try std.testing.expect(!lm.can_grant_lock(&queue, 2, .exclusive));
}

test "can_grant_lock: shared after exclusive blocks" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var lm = LockManager.init(std.testing.allocator, io);
    defer lm.deinit();

    var queue = LockQueue.init();
    defer {
        queue.requests.deinit(std.testing.allocator);
    }
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 1, .mode = .exclusive, .granted = true });
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 2, .mode = .shared, .granted = false });

    try std.testing.expect(!lm.can_grant_lock(&queue, 2, .shared));
}

test "can_grant_lock: exclusive after exclusive blocks (same txn already has it)" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var lm = LockManager.init(std.testing.allocator, io);
    defer lm.deinit();

    var queue = LockQueue.init();
    defer {
        queue.requests.deinit(std.testing.allocator);
    }
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 1, .mode = .exclusive, .granted = true });

    try std.testing.expect(lm.can_grant_lock(&queue, 1, .exclusive));
}

test "can_grant_lock: upgrade shared to exclusive when no other shared" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var lm = LockManager.init(std.testing.allocator, io);
    defer lm.deinit();

    var queue = LockQueue.init();
    defer { queue.requests.deinit(std.testing.allocator); }
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 1, .mode = .shared, .granted = true });
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 1, .mode = .exclusive, .granted = false });

    try std.testing.expect(lm.can_grant_lock(&queue, 1, .exclusive));
}

test "can_grant_lock: upgrade shared to exclusive blocks when other shared exists" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var lm = LockManager.init(std.testing.allocator, io);
    defer lm.deinit();

    var queue = LockQueue.init();
    defer { queue.requests.deinit(std.testing.allocator); }
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 1, .mode = .shared, .granted = true });
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 2, .mode = .shared, .granted = true });
    try queue.requests.append(std.testing.allocator, .{ .txn_id = 1, .mode = .exclusive, .granted = false });

    try std.testing.expect(!lm.can_grant_lock(&queue, 1, .exclusive));
}
