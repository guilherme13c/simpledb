const std = @import("std");

var current_time_provider: *const fn () i64 = default_get_time_ms;

pub fn get_time_ms() i64 {
    return current_time_provider();
}

pub fn set_time_provider(provider: *const fn () i64) void {
    current_time_provider = provider;
}

fn default_get_time_ms() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @intCast((ts.sec * 1000) + @divTrunc(ts.nsec, 1000000));
}
