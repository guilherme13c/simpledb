const std = @import("std");
const GlobalWFG = @import("../../src/storage/concurrency/wfg.zig").GlobalWFG;

test "GlobalWFG: empty graph detects no cycle" {
    var g = GlobalWFG.init(std.testing.allocator);
    defer g.deinit();
    try std.testing.expect(g.detect_cycle() == null);
}

test "GlobalWFG: acyclic chain detects no cycle" {
    var g = GlobalWFG.init(std.testing.allocator);
    defer g.deinit();
    try g.add_edge(1, 2); // 1 waits for 2
    try g.add_edge(2, 3); // 2 waits for 3
    try g.add_edge(3, 4); // 3 waits for 4
    try std.testing.expect(g.detect_cycle() == null);
}

test "GlobalWFG: two-node cycle is detected" {
    var g = GlobalWFG.init(std.testing.allocator);
    defer g.deinit();
    try g.add_edge(1, 2);
    try g.add_edge(2, 1);
    const victim = g.detect_cycle().?;
    try std.testing.expect(victim == 1 or victim == 2);
}

test "GlobalWFG: three-node cycle is detected" {
    var g = GlobalWFG.init(std.testing.allocator);
    defer g.deinit();
    try g.add_edge(1, 2);
    try g.add_edge(2, 3);
    try g.add_edge(3, 1);
    try std.testing.expect(g.detect_cycle() != null);
}

test "GlobalWFG: self-loop is a cycle" {
    var g = GlobalWFG.init(std.testing.allocator);
    defer g.deinit();
    try g.add_edge(7, 7);
    try std.testing.expectEqual(@as(u32, 7), g.detect_cycle().?);
}

test "GlobalWFG: add_edge is idempotent (no duplicate edges)" {
    var g = GlobalWFG.init(std.testing.allocator);
    defer g.deinit();
    try g.add_edge(1, 2);
    try g.add_edge(1, 2); // duplicate, ignored
    try std.testing.expectEqual(@as(usize, 1), g.edges.items.len);
}

test "GlobalWFG: cycle found within a larger graph" {
    var g = GlobalWFG.init(std.testing.allocator);
    defer g.deinit();
    // 1 -> 2 -> 3 (acyclic tail)
    try g.add_edge(1, 2);
    try g.add_edge(2, 3);
    // 4 -> 5 -> 6 -> 4 (cycle)
    try g.add_edge(4, 5);
    try g.add_edge(5, 6);
    try g.add_edge(6, 4);
    try std.testing.expect(g.detect_cycle() != null);
}
