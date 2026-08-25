const std = @import("std");
const Replication = @import("../../src/server/replication.zig").Replication;

const A = std.testing.allocator;

test "Replication: stub test suite" {
    // TODO: full protocol tests require live sockets/Server.
    try std.testing.expect(true);
}
