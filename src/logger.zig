const std = @import("std");

pub const LogLevel = enum { Debug, Info, Warn, Error };

pub const Logger = struct {
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    level: LogLevel,

    pub fn init(allocator: std.mem.Allocator, level: LogLevel) !*Logger {
        var buf = try allocator.create(std.ArrayList(u8));
        buf.* = std.ArrayList(u8).init(allocator);
        const logger = try allocator.create(Logger);
        logger.* = Logger{ .allocator = allocator, .buffer = buf, .level = level };
        return logger;
    }

    pub fn deinit(self: *Logger) void {
        self.buffer.deinit();
        self.allocator.destroy(self.buffer);
        self.allocator.destroy(self);
    }

    pub fn log(self: *Logger, lvl: LogLevel, comptime fmt: []const u8, args: anytype) void {
        // Only log if lvl >= self.level
        if (@intFromEnum(lvl) < @intFromEnum(self.level)) return;
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);
        self.buffer.appendSlice(message) catch return;
        self.buffer.appendSlice("\n") catch return;
    }

    pub fn contents(self: *Logger) []const u8 {
        return self.buffer.items;
    }
};
