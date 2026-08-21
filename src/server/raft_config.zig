const std = @import("std");

pub const ClusterState = enum {
    Cold,
    ColdNew,
};

pub const ClusterConfig = struct {
    old_members: [][]const u8, // E.g. "127.0.0.1:8080"
    new_members: ?[][]const u8,
    state: ClusterState,
    
    pub fn deinit(self: *ClusterConfig, allocator: std.mem.Allocator) void {
        for (self.old_members) |m| allocator.free(m);
        allocator.free(self.old_members);
        
        if (self.new_members) |new_m| {
            for (new_m) |m| allocator.free(m);
            allocator.free(new_m);
        }
    }
};
