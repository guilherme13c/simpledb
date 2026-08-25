const std = @import("std");
const Connection = @import("../../src/server/connection.zig").Connection;

const A = std.testing.allocator;

test "Connection: stub test suite" {
    // TODO: full protocol tests require live sockets/Server.
    try std.testing.expect(true);
}
