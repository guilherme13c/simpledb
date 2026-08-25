const std = @import("std");

test "unit test suite wired" {
    // Sentinel: ensures the aggregator produces at least one test even if files are empty.
    try std.testing.expect(true);
}
