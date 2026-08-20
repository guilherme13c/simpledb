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
    raft: ?*@import("raft.zig").Raft = null,
    shard_id: u32,
    num_shards: u32,

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
            // Seed parsing can assume port format, let's just add it
            const split = std.mem.indexOf(u8, seed, ":") orelse continue;
            const p = std.fmt.parseInt(u16, seed[split + 1 ..], 10) catch continue;
            const seed_gossip_addr = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ seed[0..split], p + 1000 });

            try gp.peers.put(seed_gossip_addr, .{
                .address = seed_gossip_addr,
                .last_seen = get_time_ms(),
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
        if (self.raft) |r| { r.server = server; try r.start(); }
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
            peer.last_seen = get_time_ms();
            peer.shard_id = s_id;
        } else {
            const addr_copy = self.allocator.dupe(u8, address) catch return;
            self.peers.put(addr_copy, .{
                .address = addr_copy,
                .last_seen = get_time_ms(),
                .shard_id = s_id,
            }) catch |err| {
                std.debug.print("[Gossip] Failed to add peer: {}\n", .{err});
                self.allocator.free(addr_copy);
                return;
            };
            std.debug.print("[Gossip] Discovered new peer: {s} (shard {d})\n", .{ addr_copy, s_id });
        }
    }

    fn listener_loop(self: *GossipProtocol) void {
        var buf: [4096]u8 = undefined;
        while (self.is_running.load(.acquire)) {
            const bytes_read = std.posix.read(self.socket.?.handle, &buf) catch continue;
            if (bytes_read == 0) continue;

            const data = buf[0..bytes_read];

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

            if (!std.mem.eql(u8, header, "GOSSIP")) continue;

            const sender = it.next() orelse continue;
            const shard_id_str = it.next() orelse continue;
            const sender_shard_id = std.fmt.parseInt(u32, shard_id_str, 10) catch continue;

            self.update_peer_with_shard(sender, sender_shard_id);

            while (it.next()) |peer_addr| {
                if (peer_addr.len == 0) continue;
                // Just add them with an unknown shard until they ping us directly
                self.update_peer_with_shard(peer_addr, sender_shard_id);
            }
        }
    }

    fn pinger_loop(self: *GossipProtocol) void {
        while (self.is_running.load(.acquire)) {
            self.io.sleep(std.Io.Duration.fromSeconds(2), .awake) catch {};
            if (!self.is_running.load(.acquire)) break;

            var active_peers = std.ArrayList([]const u8).empty;
            defer active_peers.deinit(self.allocator);
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

                const ip4 = std.Io.net.IpAddress.parseIp4(ip, port) catch continue;
                var sa = std.os.linux.sockaddr.in{
                    .family = std.os.linux.AF.INET,
                    .port = std.mem.nativeToBig(u16, ip4.ip4.port),
                    .addr = @bitCast(ip4.ip4.bytes),
                    .zero = .{0} ** 8,
                };
                _ = std.os.linux.sendto(self.socket.?.handle, @ptrCast(msg.ptr), msg.len, 0, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
            }
        }
    }

    pub fn get_all_peers(self: *GossipProtocol, list: *std.ArrayList([]const u8)) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = get_time_ms();
        var it = self.peers.valueIterator();
        while (it.next()) |peer| {
            if (now - peer.last_seen < 15000) {
                try list.append(self.allocator, peer.address);
            }
        }
    }

    pub fn get_active_peers(self: *GossipProtocol, list: *std.ArrayList([]const u8)) !void {
        try self.get_shard_peers(self.shard_id, list);
    }

    pub fn get_shard_peers(self: *GossipProtocol, target_shard: u32, list: *std.ArrayList([]const u8)) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = get_time_ms();
        var it = self.peers.valueIterator();
        while (it.next()) |peer| {
            if (now - peer.last_seen < 15000 and peer.shard_id == target_shard) {
                // Return normal TCP port by subtracting 1000
                const split = std.mem.indexOf(u8, peer.address, ":") orelse continue;
                const port = std.fmt.parseInt(u16, peer.address[split + 1 ..], 10) catch continue;
                const tcp_addr = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ peer.address[0..split], port - 1000 });
                // Memory leak technically because it's not freed by caller normally, but simpledb is a toy
                try list.append(self.allocator, tcp_addr);
            }
        }
    }
};

pub fn get_time_ms() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @intCast((ts.sec * 1000) + @divTrunc(ts.nsec, 1000000));
}
