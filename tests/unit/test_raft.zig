const std = @import("std");
const RaftGroup = @import("../../src/server/raft.zig").RaftGroup;
const Role = @import("../../src/server/raft.zig").Role;
const GossipProtocol = @import("../../src/server/gossip.zig").GossipProtocol;

const A = std.testing.allocator;

fn setup_raft_group() !RaftGroup {
    var threaded_io = std.Io.Threaded.init(A, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    var mock_gossip: GossipProtocol = undefined;
    const group = RaftGroup.init(A, io, &mock_gossip, 1, false);
    return group;
}

test "RaftGroup: initial state is Follower" {
    var group = try setup_raft_group();
    defer group.deinit();
    try std.testing.expect(group.role == Role.Follower);
    try std.testing.expect(group.current_term == 0);
    try std.testing.expect(group.voted_for == null);
}
