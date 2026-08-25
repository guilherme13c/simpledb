const std = @import("std");
const rc = @import("../../src/server/raft_config.zig");
const ClusterConfig = rc.ClusterConfig;
const ClusterState = rc.ClusterState;

const A = std.testing.allocator;

test "ClusterConfig: serialize/deserialize with empty old_members and no new_members" {
    const original = ClusterConfig{
        .old_members = &[_][]const u8{},
        .new_members = null,
        .state = .Cold,
    };

    const data = try original.serialize(A);
    defer A.free(data);
    var decoded = try ClusterConfig.deserialize(A, data);
    defer decoded.deinit(A);

    try std.testing.expectEqual(@as(usize, 0), decoded.old_members.len);
    try std.testing.expect(decoded.new_members == null);
    try std.testing.expectEqual(ClusterState.Cold, decoded.state);
}

test "ClusterConfig: serialize/deserialize with old_members and new_members (ColdNew)" {
    const old_members = [_][]const u8{ "127.0.0.1:8081", "127.0.0.1:8082" };
    const new_members = [_][]const u8{"127.0.0.1:8083"};
    const original = ClusterConfig{
        .old_members = @constCast(&old_members),
        .new_members = @constCast(&new_members),
        .state = .ColdNew,
    };

    const data = try original.serialize(A);
    defer A.free(data);
    var decoded = try ClusterConfig.deserialize(A, data);
    defer decoded.deinit(A);

    try std.testing.expectEqual(@as(usize, 2), decoded.old_members.len);
    try std.testing.expectEqualStrings("127.0.0.1:8081", decoded.old_members[0]);
    try std.testing.expectEqualStrings("127.0.0.1:8082", decoded.old_members[1]);

    try std.testing.expect(decoded.new_members != null);
    try std.testing.expectEqual(@as(usize, 1), decoded.new_members.?.len);
    try std.testing.expectEqualStrings("127.0.0.1:8083", decoded.new_members.?[0]);

    try std.testing.expectEqual(ClusterState.ColdNew, decoded.state);
}

test "ClusterConfig: clone produces independent deep copy" {
    const old_members = [_][]const u8{ "a", "b" };
    const original = ClusterConfig{
        .old_members = @constCast(&old_members),
        .new_members = null,
        .state = .Cold,
    };

    var copy = try original.clone(A);
    defer copy.deinit(A);

    try std.testing.expectEqual(@as(usize, 2), copy.old_members.len);
    try std.testing.expectEqualStrings("a", copy.old_members[0]);
    try std.testing.expectEqualStrings("b", copy.old_members[1]);
    // Pointers must differ (deep copy, not aliasing)
    try std.testing.expect(copy.old_members[0].ptr != old_members[0].ptr);
}

test "ClusterConfig: deserialize rejects truncated input (no state byte)" {
    const bad = &[_]u8{};
    try std.testing.expectError(error.EndOfStream, ClusterConfig.deserialize(A, bad));
}

test "ClusterConfig: deserialize rejects truncated old_members length" {
    const bad = [_]u8{ 0, 0, 0 }; // state byte + only 3 of 4 length bytes
    try std.testing.expectError(error.EndOfStream, ClusterConfig.deserialize(A, &bad));
}

test "ClusterConfig: deserialize rejects truncated member string" {
    // state=0, old_len=1, m_len=5, but only 2 bytes follow
    const bad = [_]u8{ 0, 1, 0, 0, 0, 5, 0, 0, 0, 'a', 'b' };
    try std.testing.expectError(error.EndOfStream, ClusterConfig.deserialize(A, &bad));
}

test "ClusterConfig: roundtrip preserves a 3-node joint consensus config" {
    const old = [_][]const u8{ "n1", "n2", "n3" };
    const new = [_][]const u8{ "n1", "n2", "n3", "n4" };
    const original = ClusterConfig{
        .old_members = @constCast(&old),
        .new_members = @constCast(&new),
        .state = .ColdNew,
    };

    const data = try original.serialize(A);
    defer A.free(data);
    var decoded = try ClusterConfig.deserialize(A, data);
    defer decoded.deinit(A);

    try std.testing.expectEqual(@as(usize, 3), decoded.old_members.len);
    try std.testing.expectEqual(@as(usize, 4), decoded.new_members.?.len);
    try std.testing.expectEqualStrings("n4", decoded.new_members.?[3]);
}
