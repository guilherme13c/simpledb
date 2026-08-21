const std = @import("std");

pub const ClusterState = enum {
    Cold,
    ColdNew,
};

pub const ClusterConfig = struct {
    old_members: [][]const u8, // E.g. "127.0.0.1:8080"
    new_members: ?[][]const u8,
    state: ClusterState,
    

    pub fn clone(self: *const ClusterConfig, allocator: std.mem.Allocator) !ClusterConfig {
        var new_old = try allocator.alloc([]const u8, self.old_members.len);
        for (self.old_members, 0..) |m, i| new_old[i] = try allocator.dupe(u8, m);
        var new_new: ?[][]const u8 = null;
        if (self.new_members) |nm| {
            var nn = try allocator.alloc([]const u8, nm.len);
            for (nm, 0..) |m, i| nn[i] = try allocator.dupe(u8, m);
            new_new = nn;
        }
        return ClusterConfig{ .old_members = new_old, .new_members = new_new, .state = self.state };
    }

        pub fn serialize(self: *const ClusterConfig, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        
        var buf: [4]u8 = undefined;
        try out.append(allocator, @intFromEnum(self.state));
        
        std.mem.writeInt(u32, &buf, @as(u32, @intCast(self.old_members.len)), .little);
        try out.appendSlice(allocator, &buf);
        for (self.old_members) |m| {
            std.mem.writeInt(u32, &buf, @as(u32, @intCast(m.len)), .little);
            try out.appendSlice(allocator, &buf);
            try out.appendSlice(allocator, m);
        }
        
        if (self.new_members) |nm| {
            std.mem.writeInt(u32, &buf, @as(u32, @intCast(nm.len)), .little);
            try out.appendSlice(allocator, &buf);
            for (nm) |m| {
                std.mem.writeInt(u32, &buf, @as(u32, @intCast(m.len)), .little);
                try out.appendSlice(allocator, &buf);
                try out.appendSlice(allocator, m);
            }
        } else {
            std.mem.writeInt(u32, &buf, 0, .little);
            try out.appendSlice(allocator, &buf);
        }
        
        return try out.toOwnedSlice(allocator);
    }

        pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !ClusterConfig {
        var offset: usize = 0;
        
        if (offset + 1 > data.len) return error.EndOfStream;
        const state_val = data[offset];
        offset += 1;
        const state: ClusterState = @enumFromInt(state_val);
        
        if (offset + 4 > data.len) return error.EndOfStream;
        const old_len = std.mem.readInt(u32, data[offset..offset+4][0..4], .little);
        offset += 4;
        
        var old_members = try allocator.alloc([]const u8, old_len);
        for (0..old_len) |i| {
            if (offset + 4 > data.len) return error.EndOfStream;
            const m_len = std.mem.readInt(u32, data[offset..offset+4][0..4], .little);
            offset += 4;
            
            if (offset + m_len > data.len) return error.EndOfStream;
            const m_buf = try allocator.alloc(u8, m_len);
            @memcpy(m_buf, data[offset..offset+m_len]);
            offset += m_len;
            old_members[i] = m_buf;
        }
        
        if (offset + 4 > data.len) return error.EndOfStream;
        const new_len = std.mem.readInt(u32, data[offset..offset+4][0..4], .little);
        offset += 4;
        
        var new_members: ?[][]const u8 = null;
        if (new_len > 0) {
            var nm = try allocator.alloc([]const u8, new_len);
            for (0..new_len) |i| {
                if (offset + 4 > data.len) return error.EndOfStream;
                const m_len = std.mem.readInt(u32, data[offset..offset+4][0..4], .little);
                offset += 4;
                
                if (offset + m_len > data.len) return error.EndOfStream;
                const m_buf = try allocator.alloc(u8, m_len);
                @memcpy(m_buf, data[offset..offset+m_len]);
                offset += m_len;
                nm[i] = m_buf;
            }
            new_members = nm;
        }
        
        return ClusterConfig{ .old_members = old_members, .new_members = new_members, .state = state };
    }

    pub fn deinit(self: *ClusterConfig, allocator: std.mem.Allocator) void {
        for (self.old_members) |m| allocator.free(m);
        allocator.free(self.old_members);
        
        if (self.new_members) |new_m| {
            for (new_m) |m| allocator.free(m);
            allocator.free(new_m);
        }
    }
};
