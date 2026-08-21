const std = @import("std");
const logger = @import("logger.zig");
const threading = @import("../threading.zig");
const consistent_hash = @import("consistent_hash.zig");
const Catalog = @import("../storage/catalog.zig").Catalog;
const connection = @import("connection.zig");
const LockManager = @import("../storage/concurrency/lock_manager.zig").LockManager;

/// Represents the main database server instance.
pub const Server = struct {
    wfg_shard_edges: std.AutoHashMap(u32, std.ArrayList(@import("../storage/concurrency/wfg.zig").Edge)),
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    logger: *logger.Logger,
    catalog: *Catalog,
    active_txn_rwlock: std.Io.RwLock,
    active_transactions: std.AutoHashMap(u32, void),
    active_txn_mutex: std.Io.Mutex,
    current_term_atomic: std.atomic.Value(u64),
    raft_connections: std.StringHashMap(std.Io.net.Stream),
    hash_ring: consistent_hash.ConsistentHashRing,
    next_txn_id: std.atomic.Value(u32),
    lock_manager: LockManager,
    is_replica: bool,
    leader_address: ?[]const u8,

    gossip: ?*@import("gossip.zig").GossipProtocol,
    raft: ?*@import("raft.zig").RaftGroup,

    shard_id: u32,
    num_shards: u32,

    // Quorum replication
    quorum_mutex: std.Io.Mutex,
    quorum_cond: std.Io.Condition,
    peer_lsns: std.AutoHashMap(i32, u32),

    /// Initializes a new Server instance.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16, catalog: *Catalog, leader_address: ?[]const u8, shard_id: u32, num_shards: u32, extra_seeds: []const []const u8) !Server {
        var gossip_ptr: ?*@import("gossip.zig").GossipProtocol = null;
        var raft_ptr: ?*@import("raft.zig").RaftGroup = null;

        var seeds = std.ArrayList([]const u8).empty;
        defer seeds.deinit(allocator);
        if (leader_address) |addr| {
            try seeds.append(allocator, addr);
        }
        for (extra_seeds) |seed| {
            try seeds.append(allocator, seed);
        }

        const gp = try allocator.create(@import("gossip.zig").GossipProtocol);
        gp.* = try @import("gossip.zig").GossipProtocol.init(allocator, io, port, seeds.items, shard_id, num_shards);

        const r = try allocator.create(@import("raft.zig").RaftGroup);
        r.* = @import("raft.zig").RaftGroup.init(allocator, io, gp, shard_id, leader_address != null);

        gp.raft = r;
        gossip_ptr = gp;
        raft_ptr = r;

        return Server{
            .allocator = allocator,
            .io = io,
            .port = port,
            .logger = try logger.Logger.init(allocator, .Info),
            .catalog = catalog,
            .active_txn_rwlock = .init,
            .active_transactions = std.AutoHashMap(u32, void).init(allocator),
            .active_txn_mutex = .init,
            .current_term_atomic = std.atomic.Value(u64).init(0),
            .raft_connections = std.StringHashMap(std.Io.net.Stream).init(allocator),
            .hash_ring = consistent_hash.ConsistentHashRing.init(allocator, 10),
            .next_txn_id = std.atomic.Value(u32).init(1),
            .lock_manager = LockManager.init(allocator, io),
            // Replicas start as followers, handled by Raft.
            // `is_replica` should probably update dynamically, but for now we set it to true if we aren't a leader later.

            .wfg_shard_edges = std.AutoHashMap(u32, std.ArrayList(@import("../storage/concurrency/wfg.zig").Edge)).init(allocator),
            .is_replica = leader_address != null,
            .leader_address = if (leader_address) |la| try allocator.dupe(u8, la) else null,
            .gossip = gossip_ptr,
            .raft = raft_ptr,
            .shard_id = shard_id,
            .num_shards = num_shards,
            .quorum_mutex = .init,
            .quorum_cond = .init,
            .peer_lsns = std.AutoHashMap(i32, u32).init(allocator),
        };
    }

    /// Starts a new transaction, recording it and capturing a snapshot.

    fn wfg_detector_loop(self: *Server) void {
        while (true) {
            self.io.sleep(std.Io.Duration.fromSeconds(2), .awake) catch {};
            
            // 1. Get local WFG edges and store them
            var local_edges = std.ArrayList(@import("../storage/concurrency/wfg.zig").Edge).empty;
            self.lock_manager.get_wait_for_edges(&local_edges) catch continue;
            
            self.active_txn_mutex.lockUncancelable(self.io);
            if (self.wfg_shard_edges.getPtr(self.shard_id)) |list| {
                list.deinit(self.allocator);
            }
            self.wfg_shard_edges.put(self.shard_id, local_edges) catch {};
            
            // 2. Broadcast local edges via Gossip
            if (self.gossip) |gp| {
                if (local_edges.items.len > 0) {
                    var buf: [4096]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&buf);
                    var writer = fbs.writer();
                    writer.print("WFG_REPORT {d} ", .{self.shard_id}) catch {};
                    var first = true;
                    for (local_edges.items) |edge| {
                        if (!first) writer.print(",", .{}) catch {};
                        first = false;
                        writer.print("{d}-{d}", .{edge.waiting, edge.holding}) catch {};
                    }
                    gp.broadcast_message(fbs.getWritten()) catch {};
                } else {
                    var buf: [64]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "WFG_REPORT {d} ", .{self.shard_id}) catch continue;
                    gp.broadcast_message(s) catch {};
                }
            }

            // 3. Build global graph and detect cycle
            var global_wfg = @import("../storage/concurrency/wfg.zig").GlobalWFG.init(self.allocator);
            var it = self.wfg_shard_edges.valueIterator();
            while (it.next()) |list| {
                for (list.items) |edge| {
                    global_wfg.add_edge(edge.waiting, edge.holding) catch {};
                }
            }
            
            if (global_wfg.detect_cycle()) |cycle_txn| {
                std.debug.print("[DeadlockDetector] Global Deadlock detected! Killing txn {d}\n", .{cycle_txn});
                self.lock_manager.kill_transaction(cycle_txn);
                
                // Broadcast kill
                if (self.gossip) |gp| {
                    var buf: [64]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "WFG_KILL {d}", .{cycle_txn}) catch continue;
                    gp.broadcast_message(s) catch {};
                }
            }
            global_wfg.deinit();
            
            self.active_txn_mutex.unlock(self.io);
        }
    }


    pub fn deinit(self: *Server) void {
        var raft_it = self.raft_connections.iterator();
        while (raft_it.next()) |entry| {
            entry.value_ptr.close(self.io);
        }
        self.raft_connections.deinit();
        self.hash_ring.deinit();
        if (self.gossip) |gp| {
            gp.deinit();
            self.allocator.destroy(gp);
        }
        if (self.raft) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
        if (self.leader_address) |la| {
            self.allocator.free(la);
        }
        self.active_transactions.deinit();
        
        var it_wfg = self.wfg_shard_edges.valueIterator();
        while (it_wfg.next()) |list| {
            list.deinit(self.allocator);
        }
        self.wfg_shard_edges.deinit();
    }

    pub fn start_txn(self: *Server) @import("../storage/wal/transaction.zig").TransactionContext {
        self.active_txn_mutex.lockUncancelable(self.io);
        defer self.active_txn_mutex.unlock(self.io);
        const txn_id = self.next_txn_id.fetchAdd(1, .monotonic);
        const snap = self.active_transactions.clone() catch unreachable;
        self.active_transactions.put(txn_id, {}) catch unreachable;
        return .{
            .txn_id = txn_id,
            .lock_manager = &self.lock_manager,
            .active_snapshot = snap,
        };
    }

    /// Ends a transaction, cleaning up its tracking.
    pub fn end_txn(self: *Server, txn_ctx: *@import("../storage/wal/transaction.zig").TransactionContext) void {
        self.active_txn_mutex.lockUncancelable(self.io);
        defer self.active_txn_mutex.unlock(self.io);
        _ = self.active_transactions.remove(txn_ctx.txn_id);
        txn_ctx.deinit();
    }

    pub fn wait_for_quorum(self: *Server, target_lsn: u32) !void {
        var active_peers = std.ArrayList([]const u8).empty;
        defer active_peers.deinit(self.allocator);

        if (self.gossip) |gp| {
            try gp.get_active_peers(&active_peers);
        }

        const cluster_size = active_peers.items.len + 1;
        const required_acks = (cluster_size / 2); // since we (leader) already have it, we need (quorum - 1) followers

        if (required_acks == 0) return; // single node cluster

        self.quorum_mutex.lockUncancelable(self.io);
        defer self.quorum_mutex.unlock(self.io);

        while (true) {
            var acks: usize = 0;
            var it = self.peer_lsns.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* >= target_lsn) {
                    acks += 1;
                }
            }
            std.debug.print("[Quorum] Waiting for LSN {d}, acks={d}/{d}\n", .{ target_lsn, acks, required_acks });
            if (acks >= required_acks) {
                break;
            }

            // Wait for next ACK or cluster topology change
            self.quorum_cond.waitUncancelable(self.io, &self.quorum_mutex);
        }
    }

    pub fn update_peer_lsn(self: *Server, fd: i32, lsn: u32) void {
        self.quorum_mutex.lockUncancelable(self.io);
        defer self.quorum_mutex.unlock(self.io);
        self.peer_lsns.put(fd, lsn) catch return;
        self.quorum_cond.broadcast(self.io);
    }

    pub fn remove_peer_lsn(self: *Server, fd: i32) void {
        self.quorum_mutex.lockUncancelable(self.io);
        defer self.quorum_mutex.unlock(self.io);
        _ = self.peer_lsns.remove(fd);
        self.quorum_cond.broadcast(self.io);
    }

    pub fn start(self: *Server) !void {
        if (self.gossip) |gp| {
            gp.start(self) catch |err| {
                std.debug.print("Failed to start Gossip Protocol: {} ", .{err});
            };
        }

        if (self.raft) |r| {
            r.start(self) catch |err| {
                std.debug.print("Failed to start Raft Protocol: {} ", .{err});
            };
        }

        if (self.is_replica) {
            const repl_thread = std.Thread.spawn(.{}, @import("replication.zig").connect_and_replicate, .{self}) catch |err| {
                std.debug.print("Failed to spawn replication client thread: {} ", .{err});
                return err;
            };
            repl_thread.detach();
        }

        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
        var listener = try address.listen(self.io, .{ .reuse_address = true });
        defer listener.socket.close(self.io);

        std.debug.print("Server listening on 127.0.0.1:{d} ", .{self.port});

        const checkpointer = threading.spawnDetach(checkpointer_loop, .{self}) catch |err| {
            self.logger.log(.Error, "Failed to spawn checkpointer thread: {}", .{err});
            return err;
        };
        // No need to detach; deterministic scheduler will run it

        while (true) {
            var stream = listener.accept(self.io) catch |err| {
                std.debug.print("Error accepting connection: {} ", .{err});
                continue;
            };
            std.debug.print("Accepted connection! (Spawning thread...) ", .{});

            const thread = std.Thread.spawn(.{}, connection.handleConnection, .{ self, stream }) catch |err| {
                std.debug.print("Failed to spawn thread: {} ", .{err});
                stream.close(self.io);
                continue;
            };
            thread.detach();
        }
    }

    pub fn execute_statement(self: *Server, stmt: @import("../query/ast.zig").Statement, txn_ctx: ?*@import("../storage/wal/transaction.zig").TransactionContext, writer: anytype, undo_stack: ?*std.ArrayList(@import("undo.zig").UndoOp)) !void {
        try @import("execution.zig").execute_statement(self.allocator, self.catalog, stmt, txn_ctx, writer, undo_stack);
    }

    fn checkpointer_loop(self: *Server) void {
        while (true) {
            self.io.sleep(std.Io.Duration.fromSeconds(5), .awake) catch {};
            self.catalog.buffer_manager.checkpoint() catch |err| {
                self.logger.log(.Error, "Checkpointer failed: {}", .{err});
            };
            self.logger.log(.Info, "[Checkpointer] Checkpoint complete.", .{});
        }
    }
};
