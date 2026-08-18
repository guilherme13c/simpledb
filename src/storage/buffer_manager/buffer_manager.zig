const std = @import("std");
const page = @import("../page/page.zig");
const sm = @import("../storage_manager/storage_manager.zig");
const wal = @import("../wal/log_manager.zig");

const pool_size = 4096;

pub const FrameState = enum {
    EMPTY,
    VALID,
};

pub const Frame = struct {
    frame_id: u32,
    page_id: ?u32,
    page: page.Page,
    pin_count: u32,
    is_dirty: bool,
    usage_count: u8,
    state: FrameState,
    latch: std.Io.RwLock,
    io_mutex: std.Io.Mutex,
};

const map_size = 8192;
const empty = std.math.maxInt(u32);

pub const BufferManager = struct {
    allocator: std.mem.Allocator,
    storage_manager: *sm.StorageManager,
    log_manager: ?*wal.LogManager,
    frames: []Frame,

    // Inline chained hash map for page_id -> frame_id
    hash_head: [map_size]u32,
    hash_next: []u32,

    hand: u32,
    pool_mutex: std.Io.Mutex,

    inline fn hash_page(page_id: u32) u32 {
        return (page_id *% 2654435769) & (map_size - 1);
    }

    pub fn init(allocator: std.mem.Allocator, storage_manager: *sm.StorageManager) !BufferManager {
        const frames = try allocator.alloc(Frame, pool_size);
        for (frames, 0..) |*f, i| {
            f.frame_id = @intCast(i);
            f.page_id = null;
            f.pin_count = 0;
            f.is_dirty = false;
            f.usage_count = 0;
            f.state = .EMPTY;
            f.latch = .init;
            f.io_mutex = .init;
        }

        const hash_next = try allocator.alloc(u32, pool_size);
        @memset(hash_next, empty);

        return BufferManager{
            .allocator = allocator,
            .storage_manager = storage_manager,
            .log_manager = null,
            .frames = frames,
            .hash_head = [_]u32{empty} ** map_size,
            .hash_next = hash_next,
            .hand = 0,
            .pool_mutex = .init,
        };
    }

    pub fn set_log_manager(self: *BufferManager, lm: *wal.LogManager) void {
        self.log_manager = lm;
    }

    pub fn deinit(self: *BufferManager) void {
        const io = self.storage_manager.io;
        self.pool_mutex.lockUncancelable(io);
        defer self.pool_mutex.unlock(io);

        for (self.frames) |*f| {
            if (f.state == .VALID and f.is_dirty) {
                if (self.log_manager) |lm| {
                    lm.flush(f.page.header.lsn) catch {};
                }
                self.storage_manager.write_page(f.page_id.?, &f.page) catch |err| {
                    std.debug.print("Failed to flush page {d}: {}\n", .{ f.page_id.?, err });
                };
            }
        }
        self.allocator.free(self.hash_next);
        self.allocator.free(self.frames);
    }

    pub fn evict_page(self: *BufferManager) !u32 {
        var iterations: u32 = 0;
        // In the worst case where all unpinned pages have usage_count=5,
        // we might need to sweep 6 times.
        while (iterations < pool_size * 6) {
            const frame_id = self.hand;
            self.hand = (self.hand + 1) % pool_size;
            iterations += 1;

            var frame = &self.frames[frame_id];
            if (frame.state == .EMPTY) {
                return frame_id;
            }
            if (frame.pin_count == 0) {
                if (frame.usage_count > 0) {
                    frame.usage_count -= 1;
                } else {
                    return frame_id;
                }
            }
        }
        return error.BufferPoolFull;
    }

    pub fn fetch_frame(self: *BufferManager, page_id: u32) !*Frame {
        const io = self.storage_manager.io;
        self.pool_mutex.lockUncancelable(io);

        var search_curr = self.hash_head[hash_page(page_id)];
        var found_frame_id: ?u32 = null;
        while (search_curr != empty) {
            if (self.frames[search_curr].page_id == page_id) {
                found_frame_id = search_curr;
                break;
            }
            search_curr = self.hash_next[search_curr];
        }

        if (found_frame_id) |frame_id| {
            var frame = &self.frames[frame_id];
            frame.pin_count += 1;
            if (frame.usage_count < 5) {
                frame.usage_count += 1;
            }
            self.pool_mutex.unlock(io);

            // Wait for any ongoing I/O on this frame
            frame.io_mutex.lockUncancelable(io);
            frame.io_mutex.unlock(io);

            return frame;
        }

        const victim_id = self.evict_page() catch |err| {
            self.pool_mutex.unlock(io);
            return err;
        };
        var frame = &self.frames[victim_id];

        // Grab the io_mutex exclusively to signify I/O in progress
        frame.io_mutex.lockUncancelable(io);

        const old_page_id = frame.page_id;
        const old_state = frame.state;
        const is_dirty = frame.is_dirty;

        if (old_page_id) |old_page| {
            const h = hash_page(old_page);
            var curr = self.hash_head[h];
            var prev: u32 = empty;
            while (curr != empty) {
                if (curr == victim_id) {
                    if (prev == empty) {
                        self.hash_head[h] = self.hash_next[curr];
                    } else {
                        self.hash_next[prev] = self.hash_next[curr];
                    }
                    break;
                }
                prev = curr;
                curr = self.hash_next[curr];
            }
        }

        frame.page_id = page_id;
        frame.pin_count = 1;
        frame.state = .VALID;
        frame.usage_count = 1;

        const new_h = hash_page(page_id);
        self.hash_next[victim_id] = self.hash_head[new_h];
        self.hash_head[new_h] = victim_id;

        // Release the pool mutex so others can use the buffer pool while we do I/O
        self.pool_mutex.unlock(io);

        if (old_state == .VALID and is_dirty) {
            if (self.log_manager) |lm| {
                lm.flush(frame.page.header.lsn) catch {};
            }
            self.storage_manager.write_page(old_page_id.?, &frame.page) catch |err| {
                frame.io_mutex.unlock(io);
                return err;
            };
        }

        self.storage_manager.read_page(page_id, &frame.page) catch |err| {
            frame.io_mutex.unlock(io);
            return err;
        };

        // At this point I/O is done.
        frame.is_dirty = false;

        frame.io_mutex.unlock(io);
        return frame;
    }

    pub fn new_frame(self: *BufferManager, page_id: u32) !*Frame {
        const io = self.storage_manager.io;
        self.pool_mutex.lockUncancelable(io);

        // Sanity check: shouldn't be in pool already
        var search_curr = self.hash_head[hash_page(page_id)];
        var found_frame_id: ?u32 = null;
        while (search_curr != empty) {
            if (self.frames[search_curr].page_id == page_id) {
                found_frame_id = search_curr;
                break;
            }
            search_curr = self.hash_next[search_curr];
        }

        if (found_frame_id) |frame_id| {
            var frame = &self.frames[frame_id];
            frame.pin_count += 1;
            if (frame.usage_count < 5) {
                frame.usage_count += 1;
            }
            self.pool_mutex.unlock(io);

            frame.io_mutex.lockUncancelable(io);

            // Zero out since it's supposed to be a newly allocated page
            @memset(std.mem.asBytes(&frame.page), 0);
            frame.is_dirty = true;

            frame.io_mutex.unlock(io);
            return frame;
        }

        const victim_id = self.evict_page() catch |err| {
            self.pool_mutex.unlock(io);
            return err;
        };
        var frame = &self.frames[victim_id];

        frame.io_mutex.lockUncancelable(io);

        const old_page_id = frame.page_id;
        const old_state = frame.state;
        const is_dirty = frame.is_dirty;

        if (old_page_id) |old_page| {
            const h = hash_page(old_page);
            var curr = self.hash_head[h];
            var prev: u32 = empty;
            while (curr != empty) {
                if (curr == victim_id) {
                    if (prev == empty) {
                        self.hash_head[h] = self.hash_next[curr];
                    } else {
                        self.hash_next[prev] = self.hash_next[curr];
                    }
                    break;
                }
                prev = curr;
                curr = self.hash_next[curr];
            }
        }

        frame.page_id = page_id;
        frame.pin_count = 1;
        frame.state = .VALID;
        frame.usage_count = 1;

        const new_h = hash_page(page_id);
        self.hash_next[victim_id] = self.hash_head[new_h];
        self.hash_head[new_h] = victim_id;

        self.pool_mutex.unlock(io);

        if (old_state == .VALID and is_dirty) {
            if (self.log_manager) |lm| {
                lm.flush(frame.page.header.lsn) catch {};
            }
            self.storage_manager.write_page(old_page_id.?, &frame.page) catch |err| {
                frame.io_mutex.unlock(io);
                return err;
            };
        }

        // NO READ_PAGE! Just zero memory.
        @memset(std.mem.asBytes(&frame.page), 0);
        frame.is_dirty = true; // Mark dirty so it gets written eventually

        frame.io_mutex.unlock(io);
        return frame;
    }

    pub fn unpin_frame(self: *BufferManager, frame: *Frame, is_dirty: bool) void {
        const io = self.storage_manager.io;
        self.pool_mutex.lockUncancelable(io);
        if (frame.pin_count > 0) {
            frame.pin_count -= 1;
        }
        if (is_dirty) {
            frame.is_dirty = true;
        }
        self.pool_mutex.unlock(io);
    }

    pub fn unpin_page(self: *BufferManager, page_id: u32, is_dirty: bool) void {
        const io = self.storage_manager.io;
        self.pool_mutex.lockUncancelable(io);
        defer self.pool_mutex.unlock(io);

        var search_curr = self.hash_head[hash_page(page_id)];
        var found_frame_id: ?u32 = null;
        while (search_curr != empty) {
            if (self.frames[search_curr].page_id == page_id) {
                found_frame_id = search_curr;
                break;
            }
            search_curr = self.hash_next[search_curr];
        }

        if (found_frame_id) |frame_id| {
            var frame = &self.frames[frame_id];
            if (frame.pin_count > 0) {
                frame.pin_count -= 1;
            }
            if (is_dirty) {
                frame.is_dirty = true;
            }
        }
    }

    pub fn lock_page(self: *BufferManager, page_id: u32, exclusive: bool) void {
        const io = self.storage_manager.io;
        self.pool_mutex.lockUncancelable(io);
        var search_curr = self.hash_head[hash_page(page_id)];
        var found_frame_id: ?u32 = null;
        while (search_curr != empty) {
            if (self.frames[search_curr].page_id == page_id) {
                found_frame_id = search_curr;
                break;
            }
            search_curr = self.hash_next[search_curr];
        }

        if (found_frame_id) |frame_id| {
            var frame = &self.frames[frame_id];
            self.pool_mutex.unlock(io);

            if (exclusive) {
                frame.latch.lockUncancelable(io);
            } else {
                frame.latch.lockSharedUncancelable(io);
            }
            return;
        }
        self.pool_mutex.unlock(io);
    }

    pub fn unlock_page(self: *BufferManager, page_id: u32, exclusive: bool) void {
        const io = self.storage_manager.io;
        self.pool_mutex.lockUncancelable(io);
        var search_curr = self.hash_head[hash_page(page_id)];
        var found_frame_id: ?u32 = null;
        while (search_curr != empty) {
            if (self.frames[search_curr].page_id == page_id) {
                found_frame_id = search_curr;
                break;
            }
            search_curr = self.hash_next[search_curr];
        }

        if (found_frame_id) |frame_id| {
            var frame = &self.frames[frame_id];
            self.pool_mutex.unlock(io);

            if (exclusive) {
                frame.latch.unlock(io);
            } else {
                frame.latch.unlockShared(io);
            }
            return;
        }
        self.pool_mutex.unlock(io);
    }
};

test "BufferManager lifecycle" {
    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const test_db = "test_buffer_pool.db";
    defer std.Io.Dir.cwd().deleteFile(io, test_db) catch {};

    var sm_inst = try sm.StorageManager.init(std.testing.allocator, io, test_db);
    try sm_inst.start();
    defer sm_inst.deinit();

    // Setup an empty file so reads don't fail for large offsets in tests
    var empty_page = std.mem.zeroes(page.Page);
    try sm_inst.write_page(0, &empty_page);
    try sm_inst.write_page(1, &empty_page);

    var bm = try BufferManager.init(std.testing.allocator, &sm_inst);
    defer bm.deinit();

    // Fetch a page, modify it, unpin it
    const p1 = try bm.fetch_frame(1);
    p1.page.header.lsn = 1234;
    bm.unpin_frame(p1, true);

    // Fetch again, should have modified data
    const p1_again = try bm.fetch_frame(1);
    try std.testing.expectEqual(@as(u32, 1234), p1_again.page.header.lsn);
    bm.unpin_frame(p1_again, false);
}
