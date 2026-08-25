const std = @import("std");
const GossipProtocol = @import("../../src/server/gossip.zig").GossipProtocol;

const A = std.testing.allocator;

test "GossipProtocol: init and deinit" {
    var threaded_io = std.Io.Threaded.init(A, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var gp = try GossipProtocol.init(A, io, 8080, &[_][]const u8{}, 0, 1);
    defer gp.deinit();

    try std.testing.expect(gp.server_address.len > 0);
    try std.testing.expect(gp.gossip_port == 9080);
    try std.testing.expect(!gp.is_running.load(.acquire));
}

test "GossipProtocol: update_peer_with_shard" {
    var threaded_io = std.Io.Threaded.init(A, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    var gp = try GossipProtocol.init(A, io, 8080, &[_][]const u8{}, 0, 1);
    defer gp.deinit();

    const addr = "192.168.1.100:8081";
    gp.update_peer_with_shard(addr, 5);

    if (gp.peers.getPtr(addr)) |peer| {
        try std.testing.expect(peer.shard_id == 5);
        try std.testing.expect(std.mem.eql(u8, peer.address, addr));
    } else {
        return error.TestFailed;
    }

    const old_time = gp.peers.get(addr).?.last_seen;
    gp.update_peer_with_shard(addr, 10);
    if (gp.peers.getPtr(addr)) |peer| {
        try std.testing.expect(peer.shard_id == 10);
        try std.testing.expect(peer.last_seen >= old_time);
    } else {
        return error.TestFailed;
    }
}
