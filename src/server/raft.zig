const std = @import("std");
const GossipProtocol = @import("gossip.zig").GossipProtocol;
const get_time_ms = @import("gossip.zig").get_time_ms;

pub const Role = enum { Follower, Candidate, Leader };

pub const RaftGroup = struct {
    group_id: u32,
    allocator: std.mem.Allocator,
    server: ?*anyopaque,
    io: std.Io,
    gossip: *GossipProtocol,
    mutex: std.Io.Mutex,
    is_running: std.atomic.Value(bool),

    role: Role,
    current_term: u64,
    voted_for: ?[]const u8,
    config: @import("raft_config.zig").ClusterConfig,
    votes_received: u32,
    last_heartbeat_ms: std.atomic.Value(i64),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, gossip: *@import("gossip.zig").GossipProtocol, group_id: u32) RaftGroup {
        return RaftGroup{
            .allocator = allocator,
            .server = null,
            .group_id = group_id,
            .io = io,
            .gossip = gossip,
            .mutex = .init,
            .is_running = std.atomic.Value(bool).init(false),
            .role = .Follower,
            .current_term = 0,
            .voted_for = null,
            .config = .{ .old_members = &[_][]const u8{}, .new_members = null, .state = .Cold },
            .votes_received = 0,
            .last_heartbeat_ms = std.atomic.Value(i64).init(get_time_ms()),
        };
    }

    pub fn deinit(self: *RaftGroup) void {
        self.config.deinit(self.allocator);
        self.is_running.store(false, .release);
        if (self.voted_for) |v| self.allocator.free(v);
    }

    pub fn start(self: *RaftGroup, server: *anyopaque) !void {
        self.server = server;
        self.is_running.store(true, .release);
        _ = try std.Thread.spawn(.{}, append_entries_loop, .{self});
        _ = try std.Thread.spawn(.{}, election_loop, .{self});
    }

    pub fn handle_message(self: *RaftGroup, data: []const u8) !void {
        var it = std.mem.splitScalar(u8, data, ' ');
        const header = it.next() orelse return;

        if (std.mem.eql(u8, header, "RAFT_VOTE_REQ")) {
            const term_str = it.next() orelse return;
            const candidate_id = it.next() orelse return;
            const term = std.fmt.parseInt(u64, term_str, 10) catch return;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (term > self.current_term) {
                self.current_term = term;
                self.role = .Follower;
                if (self.voted_for) |v| self.allocator.free(v);
                self.voted_for = try self.allocator.dupe(u8, candidate_id);

                var buf: [128]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "RAFT_VOTE_RES {d} {s} YES", .{ term, self.gossip.server_address })) |msg| {
                    try self.send_to_peer(candidate_id, msg);
                } else |_| {}
                self.last_heartbeat_ms.store(get_time_ms(), .release);
            }
        } else if (std.mem.eql(u8, header, "RAFT_VOTE_RES")) {
            const term_str = it.next() orelse return;
            _ = it.next() orelse return; // voter
            const vote = it.next() orelse return;
            const term = std.fmt.parseInt(u64, term_str, 10) catch return;

            if (std.mem.eql(u8, vote, "YES")) {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);

                if (self.role == .Candidate and term == self.current_term) {
                    self.votes_received += 1;

                    var active_peers = std.ArrayList([]const u8).empty;
                    self.gossip.get_active_peers(&active_peers) catch return;
                    defer {
                        for (active_peers.items) |p| self.allocator.free(p);
                        active_peers.deinit(self.allocator);
                    }

                    const cluster_size = active_peers.items.len + 1;
                    const majority = (cluster_size / 2) + 1;

                    if (self.votes_received >= majority) {
                        self.role = .Leader;
                        std.debug.print("[RaftGroup {d}] Node became Leader for term {d} with {d}/{d} votes\n", .{ self.group_id, self.current_term, self.votes_received, cluster_size });
                    }
                }
            }
        } else if (std.mem.eql(u8, header, "RAFT_HEARTBEAT")) {
            const term_str = it.next() orelse return;
            const leader_id = it.next() orelse return;
            const term = std.fmt.parseInt(u64, term_str, 10) catch return;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (term >= self.current_term) {
                if (term > self.current_term or self.role != .Follower) {
                    self.current_term = term;
                    self.role = .Follower;
                    std.debug.print("[RaftGroup {d}] Node acknowledged new leader: {s} for term {d}\n", .{ self.group_id, leader_id, term });
                }

                // Update server's knowledge of leader
                const server_ptr: *@import("server.zig").Server = @ptrCast(@alignCast(self.server.?));
                if (server_ptr.leader_address) |la| {
                    if (!std.mem.eql(u8, la, leader_id)) {
                        self.allocator.free(la);
                        server_ptr.leader_address = self.allocator.dupe(u8, leader_id) catch null;
                    }
                } else {
                    server_ptr.leader_address = self.allocator.dupe(u8, leader_id) catch null;
                }
                server_ptr.is_replica = true;

                self.last_heartbeat_ms.store(get_time_ms(), .release);
            }
        }
    }

    fn send_to_peer(self: *RaftGroup, peer_addr: []const u8, msg: []const u8) !void {
        const split = std.mem.indexOf(u8, peer_addr, ":") orelse return error.InvalidAddress;
        const ip = peer_addr[0..split];
        const port = try std.fmt.parseInt(u16, peer_addr[split + 1 ..], 10);
        // We use the gossip port for Raft messages
        const ip4 = try std.Io.net.IpAddress.parseIp4(ip, port + 1000);
        var sa = std.os.linux.sockaddr.in{
            .family = std.os.linux.AF.INET,
            .port = std.mem.nativeToBig(u16, ip4.ip4.port),
            .addr = @bitCast(ip4.ip4.bytes),
            .zero = .{0} ** 8,
        };
        _ = std.os.linux.sendto(self.gossip.socket.?.handle, @ptrCast(msg.ptr), msg.len, 0, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
    }

    fn broadcast_heartbeat_unlocked(self: *RaftGroup) !void {
        var active_peers = std.ArrayList([]const u8).empty;
        defer {
            for (active_peers.items) |p| self.allocator.free(p);
            active_peers.deinit(self.allocator);
        }
        self.gossip.get_active_peers(&active_peers) catch return;

        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "RAFT_HEARTBEAT {d} {s}", .{ self.current_term, self.gossip.server_address })) |msg| {
            for (active_peers.items) |peer| {
                // peer string from get_active_peers is TCP address. Raft sends via UDP Gossip.
                const split = std.mem.indexOf(u8, peer, ":") orelse continue;
                const ip = peer[0..split];
                const port = std.fmt.parseInt(u16, peer[split + 1 ..], 10) catch continue;

                var peer_gossip_addr: [128]u8 = undefined;
                const addr_str = std.fmt.bufPrint(&peer_gossip_addr, "{s}:{d}", .{ ip, port }) catch continue;
                self.send_to_peer(addr_str, msg) catch {};
            }
        } else |_| {}
    }

    fn election_loop(self: *RaftGroup) void {
        var rand = std.Random.DefaultPrng.init(@as(u64, @intCast(get_time_ms())));

        while (self.is_running.load(.acquire)) {
            const timeout_ms = rand.random().intRangeLessThan(i64, 1500, 3000);

            self.io.sleep(std.Io.Duration.fromSeconds(@as(u32, @intCast(@divTrunc(timeout_ms, 1000)))), .awake) catch {};
            if (!self.is_running.load(.acquire)) break;

            self.mutex.lockUncancelable(self.io);

            if (self.role == .Leader) {
                self.broadcast_heartbeat_unlocked() catch {};

                // Update our own server state to indicate we are the leader
                const server_ptr: *@import("server.zig").Server = @ptrCast(@alignCast(self.server.?));
                if (server_ptr.leader_address) |la| self.allocator.free(la);
                const local_tcp = std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ "127.0.0.1", server_ptr.port }) catch null;
                server_ptr.leader_address = local_tcp;
                server_ptr.is_replica = false;

                self.mutex.unlock(self.io);
                continue;
            }

            const now = get_time_ms();
            const time_since_heartbeat = now - self.last_heartbeat_ms.load(.acquire);

            if (time_since_heartbeat >= timeout_ms) {
                self.role = .Candidate;
                self.current_term += 1;
                self.votes_received = 1;
                if (self.voted_for) |v| self.allocator.free(v);
                self.voted_for = self.allocator.dupe(u8, self.gossip.server_address) catch null;
                self.last_heartbeat_ms.store(now, .release);

                std.debug.print("[RaftGroup {d}] Starting election for term {d}\n", .{ self.group_id, self.current_term});

                var active_peers = std.ArrayList([]const u8).empty;
                self.gossip.get_active_peers(&active_peers) catch {
                    self.mutex.unlock(self.io);
                    continue;
                };

                const cluster_size = active_peers.items.len + 1;
                const majority = (cluster_size / 2) + 1;

                if (self.votes_received >= majority) {
                    self.role = .Leader;
                    std.debug.print("[RaftGroup {d}] Node became Leader for term {d} with {d}/{d} votes\n", .{ self.group_id, self.current_term, self.votes_received, cluster_size });
                    for (active_peers.items) |p| self.allocator.free(p);
                    active_peers.deinit(self.allocator);
                    self.mutex.unlock(self.io);
                    continue;
                }

                var buf: [128]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "RAFT_VOTE_REQ {d} {s}", .{ self.current_term, self.gossip.server_address })) |msg| {
                    for (active_peers.items) |peer| {
                        const split = std.mem.indexOf(u8, peer, ":") orelse continue;
                        const ip = peer[0..split];
                        const port = std.fmt.parseInt(u16, peer[split + 1 ..], 10) catch continue;
                        var peer_gossip_addr: [128]u8 = undefined;
                        const addr_str = std.fmt.bufPrint(&peer_gossip_addr, "{s}:{d}", .{ ip, port }) catch continue;
                        self.send_to_peer(addr_str, msg) catch {};
                    }
                } else |_| {}

                for (active_peers.items) |p| self.allocator.free(p);
                active_peers.deinit(self.allocator);
            }

            self.mutex.unlock(self.io);
        }
    }

    
    fn append_entries_loop(self: *RaftGroup) void {
        var next_index = std.StringHashMap(u32).init(self.allocator);
        defer next_index.deinit();
        
        while (self.is_running.load(.acquire)) {
            self.io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
            if (!self.is_running.load(.acquire)) break;
            
            self.mutex.lockUncancelable(self.io);
            const is_leader = (self.role == .Leader);
            const term = self.current_term;
            self.mutex.unlock(self.io);
            
            if (!is_leader) continue;
            
            var active_peers = std.ArrayList([]const u8).empty;
            self.gossip.get_active_peers(&active_peers) catch continue;
            
            const server_ptr: *@import("server.zig").Server = @ptrCast(@alignCast(self.server.?));
            var current_lsn: u32 = 0;
            if (server_ptr.catalog.buffer_manager.log_manager) |lm| {
                current_lsn = lm.global_lsn.load(.acquire);
            }
            
            for (active_peers.items) |peer| {
                const prev_lsn = next_index.get(peer) orelse 0;
                
                // For now, we just send a heartbeat-like append entries (no payload yet)
                // In Phase 2, we will read the WAL payload and append it here
                var buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "RAFT_APPEND_ENTRIES {d} {s} {d} 0\n", .{term, self.gossip.server_address, prev_lsn})) |msg| {
                    server_ptr.active_txn_mutex.lockUncancelable(server_ptr.io);
                    var stream: ?std.Io.net.Stream = null;
                    if (server_ptr.raft_connections.get(peer)) |s| {
                        stream = s;
                    } else {
                        // Connect
                        if (std.mem.indexOf(u8, peer, ":")) |split| {
                            const ip = peer[0..split];
                            if (std.fmt.parseInt(u16, peer[split + 1 ..], 10)) |port| {
                                if (std.Io.net.IpAddress.parseIp4(ip, port)) |addr| {
                                    if (addr.connect(self.io, .{ .mode = .stream })) |new_s| {
                                        server_ptr.raft_connections.put(self.allocator.dupe(u8, peer) catch peer, new_s) catch {};
                                        stream = new_s;
                                    } else |_| {}
                                } else |_| {}
                            } else |_| {}
                        }
                    }
                    server_ptr.active_txn_mutex.unlock(server_ptr.io);
                    
                    if (stream) |s| {
                        var write_buf: [1024]u8 = undefined;
                        var writer = s.writer(server_ptr.io, &write_buf);
                        writer.interface.writeAll(msg) catch {};
                        writer.interface.flush() catch {};
                    }
                } else |_| {}
            }
            
            for (active_peers.items) |p| self.allocator.free(p);
            active_peers.deinit(self.allocator);
        }
    }

    pub fn handle_message_tcp(self: *RaftGroup, line: []const u8, writer: *std.Io.Writer) !void {
        var it = std.mem.splitScalar(u8, line, ' ');
        const header = it.next() orelse return;
        
        if (std.mem.eql(u8, header, "RAFT_APPEND_ENTRIES")) {
            const term_str = it.next() orelse return;
            const leader_id = it.next() orelse return;
            const prev_lsn_str = it.next() orelse return;
            const prev_term_str = it.next() orelse return;
            
            const term = std.fmt.parseInt(u64, term_str, 10) catch return;
            const prev_lsn = std.fmt.parseInt(u32, prev_lsn_str, 10) catch return;
            _ = prev_term_str;
            
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            
            if (term >= self.current_term) {
                if (term > self.current_term or self.role != .Follower) {
                    self.current_term = term;
                    self.role = .Follower;
                    std.debug.print("[RaftGroup {d}] Acknowledged new leader: {s} for term {d}\n", .{ self.group_id, leader_id, term });
                }
                
                const server_ptr: *@import("server.zig").Server = @ptrCast(@alignCast(self.server.?));
                if (server_ptr.leader_address) |la| {
                    if (!std.mem.eql(u8, la, leader_id)) {
                        self.allocator.free(la);
                        server_ptr.leader_address = self.allocator.dupe(u8, leader_id) catch null;
                    }
                } else {
                    server_ptr.leader_address = self.allocator.dupe(u8, leader_id) catch null;
                }
                server_ptr.is_replica = true;
                self.last_heartbeat_ms.store(get_time_ms(), .release);
                
                server_ptr.current_term_atomic.store(term, .release);
                
                writer.print("RAFT_APPEND_ENTRIES_REPLY {d} {d} YES\n", .{term, prev_lsn}) catch {};
            } else {
                writer.print("RAFT_APPEND_ENTRIES_REPLY {d} {d} NO\n", .{self.current_term, prev_lsn}) catch {};
            }
        }
    }

};
