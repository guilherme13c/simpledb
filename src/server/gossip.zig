const time = @import("../time.zig");
const std = @import("std");

pub const Peer = struct {
    address: []const u8,
    last_seen: i64,
    shard_id: u32 = 0,
};

pub const GossipProtocol = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server_address: []const u8,
    gossip_port: u16,
    peers: std.StringHashMap(Peer),
    mutex: std.Io.Mutex,
    is_running: std.atomic.Value(bool),
    socket: ?std.Io.net.Socket = null,
    raft: ?*@import("raft.zig").RaftGroup = null,
    shard_id: u32,
    num_shards: u32,
    server_ptr: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16, seeds: []const []const u8, shard_id: u32, num_shards: u32) !GossipProtocol {
        const server_address = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
        var gp = GossipProtocol{
            .allocator = allocator,
            .io = io,
            .server_address = server_address,
            .gossip_port = port + 1000,
            .peers = std.StringHashMap(Peer).init(allocator),
            .mutex = .init,
            .is_running = std.atomic.Value(bool).init(false),
            .shard_id = shard_id,
            .num_shards = num_shards,
        };

        for (seeds) |seed| {
            // Seed is already TCP address, store as is
            const seed_dup = try allocator.dupe(u8, seed);
            try gp.peers.put(seed_dup, .{
                .address = seed_dup,
                .last_seen = time.get_time_ms(),
                .shard_id = 0,
            });
        }
        return gp;
    }

    pub fn deinit(self: *GossipProtocol) void {
        self.is_running.store(false, .release);
        if (self.socket) |s| s.close(self.io);

        var it = self.peers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.peers.deinit();
        self.allocator.free(self.server_address);
    }

    pub fn start(self: *GossipProtocol, server: *anyopaque) !void {
        self.server_ptr = server;
        if (self.raft) |r| { r.server = server; try r.start(server); }
        self.is_running.store(true, .release);

        var ip4 = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.gossip_port);
        self.socket = try ip4.bind(self.io, .{ .mode = .dgram });
        std.debug.print("Gossip Protocol started on UDP port {d}\n", .{self.gossip_port});

        _ = try std.Thread.spawn(.{}, listener_loop, .{self});
        _ = try std.Thread.spawn(.{}, pinger_loop, .{self});
    }

    pub fn update_peer_with_shard(self: *GossipProtocol, address: []const u8, s_id: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.peers.getPtr(address)) |peer| {
            peer.last_seen = time.get_time_ms();
            peer.shard_id = s_id;
        } else {
            const addr_copy = self.allocator.dupe(u8, address) catch return;
            self.peers.put(addr_copy, .{
                .address = addr_copy,
                .last_seen = time.get_time_ms(),
                .shard_id = s_id,
            }) catch |err| {
                std.debug.print("[Gossip] Failed to add peer: {}\n", .{err});
                self.allocator.free(addr_copy);
                return;
            };
            std.debug.print("[Gossip] Discovered new peer: {s} (shard {d})\n", .{ addr_copy, s_id });
        }
    }


    pub fn broadcast_message(self: *GossipProtocol, msg: []const u8) !void {
        var active_peers = std.ArrayList([]const u8).empty;
        defer {
            for (active_peers.items) |p| self.allocator.free(p);
            active_peers.deinit(self.allocator);
        }
        self.get_all_peers(&active_peers) catch return;

        for (active_peers.items) |peer_addr| {
            var iter = std.mem.splitScalar(u8, peer_addr, ':');
            const ip = iter.next() orelse continue;
            const port_str = iter.next() orelse continue;
            const port = std.fmt.parseInt(u16, port_str, 10) catch continue;
            const gossip_port = port + 1000;

            const dest = std.Io.net.IpAddress.parseIp4(ip, gossip_port) catch continue;
            self.socket.?.send(self.io, &dest, msg) catch continue;
        }
    }

    fn listener_loop(self: *GossipProtocol) void {
        var buf: [4096]u8 = undefined;
        while (self.is_running.load(.acquire)) {
            const incoming = self.socket.?.receive(self.io, &buf) catch continue;
            if (incoming.data.len == 0) continue;

            const data = incoming.data;

            var it = std.mem.splitScalar(u8, data, ' ');
            const header = it.next() orelse continue;

            if (std.mem.startsWith(u8, header, "RAFT_")) {
                if (self.raft) |raft| {
                    raft.handle_message(data) catch |err| {
                        std.debug.print("[Gossip] Failed to handle Raft message: {}\n", .{err});
                    };
                }
                continue;
            }


            if (std.mem.eql(u8, header, "WFG_KILL")) {
                const txn_str = it.next() orelse continue;
                const txn_id = std.fmt.parseInt(u32, txn_str, 10) catch continue;
                if (self.server_ptr) |ptr| {
                    const srv = @as(*@import("server.zig").Server, @ptrCast(@alignCast(ptr)));
                    srv.lock_manager.kill_transaction(txn_id);
                    srv.active_txn_mutex.lockUncancelable(srv.io);
                    srv.active_txn_mutex.unlock(srv.io);
                }
                continue;
            }
            
            if (std.mem.eql(u8, header, "WFG_REPORT")) {
                const shard_str = it.next() orelse continue;
                const r_shard_id = std.fmt.parseInt(u32, shard_str, 10) catch continue;
                
                if (self.server_ptr) |ptr| {
                    const srv = @as(*@import("server.zig").Server, @ptrCast(@alignCast(ptr)));
                    var new_edges = std.ArrayList(@import("../storage/concurrency/wfg.zig").Edge).empty;
                    
                    const edges_str = it.next() orelse "";
                    if (edges_str.len > 0) {
                        var edge_it = std.mem.splitScalar(u8, edges_str, ',');
                        while (edge_it.next()) |edge_str| {
                            var dash_it = std.mem.splitScalar(u8, edge_str, '-');
                            const w_str = dash_it.next() orelse continue;
                            const h_str = dash_it.next() orelse continue;
                            const w = std.fmt.parseInt(u32, w_str, 10) catch continue;
                            const h = std.fmt.parseInt(u32, h_str, 10) catch continue;
                            new_edges.append(self.allocator, .{ .waiting = w, .holding = h }) catch continue;
                        }
                    }
                    
                    srv.active_txn_mutex.lockUncancelable(srv.io);
                    if (srv.wfg_shard_edges.getPtr(r_shard_id)) |list| {
                        list.deinit(srv.allocator);
                    }
                    srv.wfg_shard_edges.put(r_shard_id, new_edges) catch {};
                    srv.active_txn_mutex.unlock(srv.io);
                }
                continue;
            }

            if (!std.mem.eql(u8, header, "GOSSIP")) continue;

            const sender = it.next() orelse continue;
            const shard_id_str = it.next() orelse continue;
            const sender_shard_id = std.fmt.parseInt(u32, shard_id_str, 10) catch continue;

            self.update_peer_with_shard(sender, sender_shard_id);

            while (it.next()) |peer_list| {
                if (peer_list.len == 0) continue;
                var peer_it = std.mem.splitScalar(u8, peer_list, ',');
                while (peer_it.next()) |peer_addr| {
                    if (peer_addr.len == 0 or std.mem.eql(u8, peer_addr, self.server_address)) continue;
                    self.update_peer_with_shard(peer_addr, sender_shard_id);
                }
            }
        }
    }

    fn pinger_loop(self: *GossipProtocol) void {
        while (self.is_running.load(.acquire)) {
            self.io.sleep(std.Io.Duration.fromSeconds(2), .awake) catch {};
            if (!self.is_running.load(.acquire)) break;

            var active_peers = std.ArrayList([]const u8).empty;
            defer {
                for (active_peers.items) |p| self.allocator.free(p);
                active_peers.deinit(self.allocator);
            }
            self.get_all_peers(&active_peers) catch continue;

            var buf: [2048]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "GOSSIP {s} {d} ", .{ self.server_address, self.shard_id }) catch continue;

            var payload = std.ArrayList(u8).empty;
            defer payload.deinit(self.allocator);
            payload.appendSlice(self.allocator, s) catch continue;

            var first = true;
            for (active_peers.items) |p| {
                if (first) {
                    first = false;
                } else {
                    payload.append(self.allocator, ',') catch continue;
                }
                payload.appendSlice(self.allocator, p) catch continue;
            }

            const msg = payload.items;

            for (active_peers.items) |peer_addr| {
                const split = std.mem.indexOf(u8, peer_addr, ":") orelse continue;
                const ip = peer_addr[0..split];
                const port = std.fmt.parseInt(u16, peer_addr[split + 1 ..], 10) catch continue;
                const gossip_port = port + 1000;

                const dest = std.Io.net.IpAddress.parseIp4(ip, gossip_port) catch continue;
                self.socket.?.send(self.io, &dest, msg) catch continue;
            }
        }
    }

    pub fn get_all_peers(self: *GossipProtocol, list: *std.ArrayList([]const u8)) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = time.get_time_ms();
        var it = self.peers.valueIterator();
        while (it.next()) |peer| {
            if (std.mem.eql(u8, peer.address, self.server_address)) continue;
            if (now - peer.last_seen < 15000) {
                const tcp_addr = try self.allocator.dupe(u8, peer.address);
                try list.append(self.allocator, tcp_addr);
            }
        }
    }

    pub fn get_active_peers(self: *GossipProtocol, list: *std.ArrayList([]const u8)) !void {
        try self.get_shard_peers(self.shard_id, list);
    }

    pub fn get_shard_peers(self: *GossipProtocol, target_shard: u32, list: *std.ArrayList([]const u8)) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = time.get_time_ms();
        var it = self.peers.valueIterator();
        while (it.next()) |peer| {
            if (std.mem.eql(u8, peer.address, self.server_address)) continue;
            if (now - peer.last_seen < 15000 and peer.shard_id == target_shard) {
                const tcp_addr = try self.allocator.dupe(u8, peer.address);
                try list.append(self.allocator, tcp_addr);
            }
        }
    }
};
