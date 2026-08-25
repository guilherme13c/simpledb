const std = @import("std");

// Aggregator root for the per-module unit test suite.
// Each test file imports its targets relative to its own location under src/unit/.
// Run with: zig build test-unit
comptime {
    _ = @import("tests/unit/test_transaction.zig");
    _ = @import("tests/unit/test_hash_index.zig");
    _ = @import("tests/unit/test_log_record.zig");
    _ = @import("tests/unit/test_slotted_view.zig");
    _ = @import("tests/unit/test_wfg.zig");
    _ = @import("tests/unit/test_lexer.zig");
    _ = @import("tests/unit/test_parser.zig");
    _ = @import("tests/unit/test_executor_pipeline.zig");
    _ = @import("tests/unit/test_raft_config.zig");
    _ = @import("tests/unit/test_undo.zig");
    _ = @import("tests/unit/test_raft.zig");
    _ = @import("tests/unit/test_replication.zig");
    _ = @import("tests/unit/test_connection.zig");
}

test "unit test suite wired" {
    // Sentinel: ensures the aggregator produces at least one test even if files are empty.
    try std.testing.expect(true);
}
