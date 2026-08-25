const std = @import("std");

comptime {
    _ = @import("tests/unit/test_connection.zig");
    _ = @import("tests/unit/test_executor_pipeline.zig");
    _ = @import("tests/unit/test_gossip.zig");
    _ = @import("tests/unit/test_hash_index.zig");
    _ = @import("tests/unit/test_lexer.zig");
    _ = @import("tests/unit/test_log_record.zig");
    _ = @import("tests/unit/test_parser.zig");
    _ = @import("tests/unit/test_raft.zig");
    _ = @import("tests/unit/test_raft_config.zig");
    _ = @import("tests/unit/test_replication.zig");
    _ = @import("tests/unit/test_slotted_view.zig");
    _ = @import("tests/unit/test_transaction.zig");
    _ = @import("tests/unit/test_undo.zig");
    _ = @import("tests/unit/test_wfg.zig");
}

test "unit test runner wired" {
    try std.testing.expect(true);
}
