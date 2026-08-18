const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) {
        std.debug.print("Usage: {s} <output_name> <executable> [args...]\n", .{args[0]});
        std.process.exit(1);
    }

    const output_name = args[1];
    const exec_path = args[2];
    const exec_args = args[3..];

    // Create profiling directory
    std.Io.Dir.cwd().createDirPath(init.io, "profiling") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    // Create tmp directory for perf.data files
    std.Io.Dir.cwd().createDirPath(init.io, "tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Download scripts if not exist
    inline for (.{
        .{ "stackcollapse-perf.pl", "https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl" },
        .{ "flamegraph.pl", "https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl" },
    }) |script_info| {
        const file_name = try std.fmt.allocPrint(allocator, "tools/{s}", .{script_info[0]});
        defer allocator.free(file_name);
        const url = script_info[1];
        if (std.Io.Dir.cwd().openFile(init.io, file_name, .{})) |f| {
            f.close(init.io);
        } else |_| {
            std.debug.print("Downloading {s}...\n", .{file_name});
            const wget_result = try std.process.run(allocator, init.io, .{
                .argv = &[_][]const u8{ "wget", "-q", url, "-O", file_name },
            });
            allocator.free(wget_result.stdout);
            allocator.free(wget_result.stderr);
            
            const chmod_result = try std.process.run(allocator, init.io, .{
                .argv = &[_][]const u8{ "chmod", "+x", file_name },
            });
            allocator.free(chmod_result.stdout);
            allocator.free(chmod_result.stderr);
        }
    }

    std.debug.print("Running perf record on {s}...\n", .{exec_path});
    
    const perf_data = try std.fmt.allocPrint(allocator, "tmp/perf_{s}.data", .{output_name});
    
    var perf_record_args = std.ArrayList([]const u8).empty;
    try perf_record_args.appendSlice(allocator, &[_][]const u8{ "perf", "record", "-o", perf_data, "-F", "999", "-g", "--", exec_path });
    try perf_record_args.appendSlice(allocator, exec_args);
    
    const perf_record_result = try std.process.run(allocator, init.io, .{
        .argv = perf_record_args.items,
    });
    allocator.free(perf_record_result.stdout);
    allocator.free(perf_record_result.stderr);

    if (perf_record_result.term != .exited or perf_record_result.term.exited != 0) {
        std.debug.print("perf record failed\n", .{});
        std.process.exit(1);
    }

    std.debug.print("Generating profiling/{s}.svg...\n", .{output_name});
    
    // Instead of piped stdout, we can use a shell or chain child processes via fds.
    // For simplicity, we just use sh -c "perf script | ./tools/stackcollapse-perf.pl | ./tools/flamegraph.pl > profiling/..."
    
    const out_path = try std.fmt.allocPrint(allocator, "profiling/{s}.svg", .{output_name});
    const cmd = try std.fmt.allocPrint(allocator, "perf script -i {s} | ./tools/stackcollapse-perf.pl | ./tools/flamegraph.pl > {s}", .{perf_data, out_path});
    
    const sh_result = try std.process.run(allocator, init.io, .{
        .argv = &[_][]const u8{ "sh", "-c", cmd },
    });
    allocator.free(sh_result.stdout);
    allocator.free(sh_result.stderr);

    if (sh_result.term != .exited or sh_result.term.exited != 0) {
        std.debug.print("flamegraph generation failed\n", .{});
        std.process.exit(1);
    }
    
    std.debug.print("Done! Flamegraph saved to {s}\n", .{out_path});
}
