const std = @import("std");
const GossipProtocol = @import("gossip.zig").GossipProtocol;
const get_time_ms = @import("gossip.zig").get_time_ms;

pub const Role = enum { Follower, Candidate, Leader };

pub const Raft = struct {
    allocator: std.mem.Allocator,
    server: ?*anyopaque,
    io: std.Io,
    gossip: *GossipProtocol,
    mutex: std.Io.Mutex,
    is_running: std.atomic.Value(bool),

    role: Role,
    current_term: u64,
    voted_for: ?[]const u8,
    votes_received: u32,
    last_heartbeat_ms: std.atomic.Value(i64),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, gossip: *GossipProtocol) Raft {
        return Raft{
            .allocator = allocator,
            .server = null,
            .io = io,
            .gossip = gossip,
            .mutex = .init,
            .is_running = std.atomic.Value(bool).init(false),
            .role = .Follower,
            .current_term = 0,
            .voted_for = null,
            .votes_received = 0,
            .last_heartbeat_ms = std.atomic.Value(i64).init(get_time_ms()),
        };
    }

    pub fn deinit(self: *Raft) void {
        self.is_running.store(false, .release);
        if (self.voted_for) |v| self.allocator.free(v);
    }

    pub fn start(self: *Raft) !void {
        self.is_running.store(true, .release);
        _ = try std.Thread.spawn(.{}, election_loop, .{self});
    }

    pub fn handle_message(self: *Raft, data: []const u8) !void {
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
                        std.debug.print("[Raft] Node became Leader for term {d} with {d}/{d} votes\n", .{ self.current_term, self.votes_received, cluster_size });
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
                    std.debug.print("[Raft] Node acknowledged new leader: {s} for term {d}\n", .{ leader_id, term });
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

    fn send_to_peer(self: *Raft, peer_addr: []const u8, msg: []const u8) !void {
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

    fn broadcast_heartbeat_unlocked(self: *Raft) !void {
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

    fn election_loop(self: *Raft) void {
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

                std.debug.print("[Raft] Starting election for term {d}\n", .{self.current_term});

                var active_peers = std.ArrayList([]const u8).empty;
                self.gossip.get_active_peers(&active_peers) catch {
                    self.mutex.unlock(self.io);
                    continue;
                };

                const cluster_size = active_peers.items.len + 1;
                const majority = (cluster_size / 2) + 1;

                if (self.votes_received >= majority) {
                    self.role = .Leader;
                    std.debug.print("[Raft] Node became Leader for term {d} with {d}/{d} votes\n", .{ self.current_term, self.votes_received, cluster_size });
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
};
