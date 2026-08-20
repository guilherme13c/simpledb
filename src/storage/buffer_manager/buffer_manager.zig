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

    flusher_thread: std.Thread,
    stop_flusher: std.atomic.Value(bool),
    flusher_event: std.Io.Event,

    prefetch_thread: std.Thread,
    prefetch_event: std.Io.Event,
    prefetch_queue: [64]u32,
    prefetch_head: std.atomic.Value(usize),
    prefetch_tail: std.atomic.Value(usize),

    last_fetched_page_id: std.atomic.Value(u32),
    sequential_counter: std.atomic.Value(u32),

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
            .flusher_thread = undefined,
            .stop_flusher = std.atomic.Value(bool).init(false),
            .flusher_event = .unset,
            .prefetch_thread = undefined,
            .prefetch_event = .unset,
            .prefetch_queue = undefined,
            .prefetch_head = std.atomic.Value(usize).init(0),
            .prefetch_tail = std.atomic.Value(usize).init(0),
            .last_fetched_page_id = std.atomic.Value(u32).init(empty),
            .sequential_counter = std.atomic.Value(u32).init(0),
        };
    }

    pub fn set_log_manager(self: *BufferManager, lm: *wal.LogManager) void {
        self.log_manager = lm;
    }

    pub fn start(self: *BufferManager) !void {
        self.flusher_thread = try std.Thread.spawn(.{}, flusher_loop, .{self});
        self.prefetch_thread = try std.Thread.spawn(.{}, prefetcher_loop, .{self});
    }

    fn flusher_loop(self: *BufferManager) void {
        const io = self.storage_manager.io;
        while (!self.stop_flusher.load(.monotonic)) {
            // Wake up every 10ms or when explicitly signaled
            const timeout = std.Io.Timeout{
                .duration = .{
                    .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms },
                    .clock = .awake,
                },
            };
            self.flusher_event.waitTimeout(io, timeout) catch {};
            self.flusher_event.reset();
            
            if (self.stop_flusher.load(.monotonic)) break;

            var batch_page_ids: [128]u32 = undefined;
            var batch_pages: [128]*const page.Page = undefined;
            var batch_frame_ids: [128]u32 = undefined;
            var batch_count: usize = 0;

            self.pool_mutex.lockUncancelable(io);
            for (self.frames) |*f| {
                if (batch_count >= 128) break;
                if (f.state == .VALID and f.is_dirty and f.pin_count == 0) {
                    f.pin_count += 1; // Pin it so it doesn't get evicted while flushing
                    f.io_mutex.lockUncancelable(io);
                    batch_page_ids[batch_count] = f.page_id.?;
                    batch_pages[batch_count] = &f.page;
                    batch_frame_ids[batch_count] = f.frame_id;
                    batch_count += 1;
                }
            }
            self.pool_mutex.unlock(io);

            if (batch_count > 0) {
                // WAL flush
                if (self.log_manager) |lm| {
                    var max_lsn: u32 = 0;
                    for (batch_pages[0..batch_count]) |p| {
                        if (p.header.lsn > max_lsn) max_lsn = p.header.lsn;
                    }
                    if (max_lsn > 0) {
                        lm.flush(max_lsn) catch {};
                    }
                }

                // Batch write to disk
                self.storage_manager.write_pages(batch_page_ids[0..batch_count], batch_pages[0..batch_count]) catch {};

                // Unpin and mark clean
                self.pool_mutex.lockUncancelable(io);
                for (batch_frame_ids[0..batch_count]) |frame_id| {
                    var f = &self.frames[frame_id];
                    f.is_dirty = false;
                    f.pin_count -= 1;
                    f.io_mutex.unlock(io);
                }
                self.pool_mutex.unlock(io);
            }
        }
    }

    fn enqueue_prefetch(self: *BufferManager, start_page_id: u32) void {
        const tail = self.prefetch_tail.load(.monotonic);
        const next_tail = (tail + 1) % self.prefetch_queue.len;
        if (next_tail == self.prefetch_head.load(.monotonic)) {
            return; // Queue full
        }
        self.prefetch_queue[tail] = start_page_id;
        self.prefetch_tail.store(next_tail, .release);
        self.prefetch_event.set(self.storage_manager.io);
    }

    fn do_prefetch(self: *BufferManager, start_page_id: u32, count: u32) void {
        const io = self.storage_manager.io;
        var batch_page_ids: [128]u32 = undefined;
        var batch_destinations: [128]*page.Page = undefined;
        var batch_frames: [128]*Frame = undefined;
        var batch_count: usize = 0;

        for (0..count) |i| {
            const page_id = start_page_id + @as(u32, @intCast(i));
            
            self.pool_mutex.lockUncancelable(io);
            // Check if already in pool
            var search_curr = self.hash_head[hash_page(page_id)];
            var found = false;
            while (search_curr != empty) {
                if (self.frames[search_curr].page_id == page_id) {
                    found = true;
                    break;
                }
                search_curr = self.hash_next[search_curr];
            }
            
            if (found) {
                self.pool_mutex.unlock(io);
                continue;
            }

            const victim_id = self.evict_page() catch {
                self.pool_mutex.unlock(io);
                break; // Pool full, stop prefetching
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
            frame.pin_count = 1; // Temporarily pin it
            frame.state = .VALID;
            frame.usage_count = 1;

            const new_h = hash_page(page_id);
            self.hash_next[victim_id] = self.hash_head[new_h];
            self.hash_head[new_h] = victim_id;

            // Synchronously flush dirty victim if necessary
            if (old_state == .VALID and is_dirty) {
                self.pool_mutex.unlock(io);
                if (self.log_manager) |lm| {
                    lm.flush(frame.page.header.lsn) catch {};
                }
                self.storage_manager.write_page(old_page_id.?, &frame.page) catch {
                    frame.io_mutex.unlock(io);
                    continue;
                };
            } else {
                self.pool_mutex.unlock(io);
            }

            batch_page_ids[batch_count] = page_id;
            batch_destinations[batch_count] = &frame.page;
            batch_frames[batch_count] = frame;
            batch_count += 1;
        }

        if (batch_count > 0) {
            self.storage_manager.read_pages(batch_page_ids[0..batch_count], batch_destinations[0..batch_count]) catch {};

            self.pool_mutex.lockUncancelable(io);
            for (batch_frames[0..batch_count]) |f| {
                f.is_dirty = false;
                f.pin_count -= 1; // Unpin it
                f.io_mutex.unlock(io);
            }
            self.pool_mutex.unlock(io);
        }
    }

    fn prefetcher_loop(self: *BufferManager) void {
        const io = self.storage_manager.io;
        while (!self.stop_flusher.load(.monotonic)) {
            const timeout = std.Io.Timeout{
                .duration = .{ .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms }, .clock = .awake },
            };
            self.prefetch_event.waitTimeout(io, timeout) catch {};
            self.prefetch_event.reset();

            if (self.stop_flusher.load(.monotonic)) break;

            while (true) {
                const head = self.prefetch_head.load(.acquire);
                if (head == self.prefetch_tail.load(.monotonic)) break;

                const start_page_id = self.prefetch_queue[head];
                self.prefetch_head.store((head + 1) % self.prefetch_queue.len, .monotonic);

                self.do_prefetch(start_page_id, 32);
            }
        }
    }

    pub fn deinit(self: *BufferManager) void {
        const io = self.storage_manager.io;
        self.stop_flusher.store(true, .monotonic);
        self.flusher_event.set(io);
        self.prefetch_event.set(io);
        self.flusher_thread.join();
        self.prefetch_thread.join();

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

    pub fn checkpoint(self: *BufferManager) !void {
        const io = self.storage_manager.io;
        
        // 1. Force flush all dirty frames synchronously
        self.pool_mutex.lockUncancelable(io);
        for (self.frames) |*f| {
            if (f.state == .VALID and f.is_dirty) {
                f.io_mutex.lockUncancelable(io);
                if (f.is_dirty) {
                    if (self.log_manager) |lm| {
                        lm.flush(f.page.header.lsn) catch {};
                    }
                    self.storage_manager.write_page(f.page_id.?, &f.page) catch |err| {
                        std.debug.print("Checkpoint flush failed for page {d}: {}\n", .{ f.page_id.?, err });
                    };
                    f.is_dirty = false;
                }
                f.io_mutex.unlock(io);
            }
        }
        self.pool_mutex.unlock(io);

        // 2. Append checkpoint record to WAL
        if (self.log_manager) |lm| {
            _ = try lm.append_record(0, 0, .checkpoint, 0, 0, &[_]u8{});
        }
    }

    pub fn evict_page(self: *BufferManager) !u32 {
        var iterations: u32 = 0;
        var first_pass_clean_only = true;
        var clean_pages_in_sweep: u32 = 0;
        
        while (iterations < pool_size * 12) {
            const frame_id = self.hand;
            self.hand = (self.hand + 1) % pool_size;
            iterations += 1;

            if (iterations % pool_size == 0) {
                if (clean_pages_in_sweep == 0) {
                    first_pass_clean_only = false;
                }
                clean_pages_in_sweep = 0;
            }

            var frame = &self.frames[frame_id];

            if (frame.state == .EMPTY) {
                return frame_id;
            }

            if (frame.pin_count == 0) {
                if (!frame.is_dirty) {
                    clean_pages_in_sweep += 1;
                } else {
                    self.flusher_event.set(self.storage_manager.io);
                }

                if (frame.usage_count > 0) {
                    frame.usage_count -= 1;
                }
                
                if (frame.usage_count == 0) {
                    if (frame.is_dirty and first_pass_clean_only) {
                        continue;
                    }
                    return frame_id;
                }
            }
        }
        return error.BufferPoolFull;
    }

    pub fn fetch_frame(self: *BufferManager, page_id: u32) !*Frame {
        const last_fetched = self.last_fetched_page_id.load(.monotonic);
        if (last_fetched != empty and page_id == last_fetched + 1) {
            const seq_count = self.sequential_counter.load(.monotonic) + 1;
            self.sequential_counter.store(seq_count, .monotonic);
            if (seq_count >= 32) {
                self.enqueue_prefetch(page_id + 1);
                self.sequential_counter.store(0, .monotonic);
            }
        } else {
            self.sequential_counter.store(0, .monotonic);
        }
        self.last_fetched_page_id.store(page_id, .monotonic);

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
    try bm.start();
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
