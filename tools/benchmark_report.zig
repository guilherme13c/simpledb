const std = @import("std");
const json = std.json;

fn parseOutput(allocator: std.mem.Allocator, output: []const u8) !std.StringHashMap(u64) {
    var metrics = std.StringHashMap(u64).init(allocator);
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            if (std.mem.endsWith(u8, trimmed, " ms")) {
                const name = std.mem.trim(u8, trimmed[0..colon_pos], " ");
                const time_str = std.mem.trim(u8, trimmed[colon_pos + 1 .. trimmed.len - 3], " ");
                if (std.fmt.parseInt(u64, time_str, 10)) |time_ms| {
                    try metrics.put(name, time_ms);
                } else |_| {}
            }
        }
    }
    return metrics;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("Usage: {s} <benchmark_executable>\n", .{args[0]});
        std.process.exit(1);
    }
    const bench_exec = args[1];

    std.debug.print("Running benchmarks...\n", .{});

    const run_result = try std.process.run(allocator, init.io, .{
        .argv = &[_][]const u8{ bench_exec, "all" },
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("Benchmarks failed!\n{s}\n", .{run_result.stderr});
        std.process.exit(1);
    }

    const new_metrics = try parseOutput(allocator, run_result.stderr); // zig prints to stderr

    const cache_dir = ".benchmark_cache";
    const cache_file = ".benchmark_cache/latest.json";
    
    std.Io.Dir.cwd().createDirPath(init.io, cache_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var old_metrics = std.StringHashMap(u64).init(allocator);
    var has_old = false;

    if (std.Io.Dir.cwd().statFile(init.io, cache_file, .{})) |stat| {
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);
        _ = try std.Io.Dir.cwd().readFile(init.io, cache_file, content);
        const parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch null;
        if (parsed) |p| {
            if (p.value == .object) {
                var it = p.value.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .integer) {
                        try old_metrics.put(entry.key_ptr.*, @intCast(entry.value_ptr.integer));
                    }
                }
                has_old = true;
            }
        }
    } else |_| {}

    std.debug.print("\n================ BENCHMARK REPORT ================\n", .{});
    if (has_old) {
        std.debug.print("{s:<40} | {s:<15} | {s:<20}\n", .{"Benchmark", "Time (ms)", "Change"});
        std.debug.print("{s}\n", .{"-" ** 80});
        var it = new_metrics.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const new_val = entry.value_ptr.*;
            if (old_metrics.get(name)) |old_val| {
                const diff: f64 = @as(f64, @floatFromInt(new_val)) - @as(f64, @floatFromInt(old_val));
                const diff_pct: f64 = (diff / @as(f64, @floatFromInt(old_val))) * 100.0;
                const sign = if (diff_pct > 0) "+" else "";
                
                var status_msg: []const u8 = "";
                if (diff_pct > 5.0) {
                    status_msg = "(Performance has regressed)";
                } else if (diff_pct < -5.0) {
                    status_msg = "(Performance has improved)";
                } else {
                    status_msg = "(No change in performance detected - noise)";
                }
                
                std.debug.print("{s:<40} | {d:<15} | {s}{d:.2}% {s}\n", .{name, new_val, sign, diff_pct, status_msg});
            } else {
                std.debug.print("{s:<40} | {d:<15} | N/A\n", .{name, new_val});
            }
        }
    } else {
        std.debug.print("No previous benchmark run found to compare against.\n\n", .{});
        std.debug.print("{s:<50} | {s:<15}\n", .{"Benchmark", "Current (ms)"});
        std.debug.print("{s}\n", .{"-" ** 68});
        var it = new_metrics.iterator();
        while (it.next()) |entry| {
            std.debug.print("{s:<50} | {d:<15}\n", .{entry.key_ptr.*, entry.value_ptr.*});
        }
    }
    std.debug.print("==================================================\n\n", .{});

    // Save to cache
    const file = try std.Io.Dir.cwd().createFile(init.io, cache_file, .{});
    defer file.close(init.io);
    
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(init.io, &buffer);
    var write_stream: std.json.Stringify = .{
        .writer = &file_writer.interface,
        .options = .{ .whitespace = .indent_4 },
    };
    try write_stream.beginObject();
    var it2 = new_metrics.iterator();
    while (it2.next()) |entry| {
        try write_stream.objectField(entry.key_ptr.*);
        try write_stream.write(entry.value_ptr.*);
    }
    try write_stream.endObject();
    try file_writer.flush();
}
