const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the main module
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the main executable
    const exe = b.addExecutable(.{
        .name = "simpledb",
        .root_module = main_mod,
    });

    // Install the executable
    b.installArtifact(exe);

    // Add a 'run' step to execute the server
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the simpledb server");
    run_step.dependOn(&run_cmd.step);

    // Create the test module
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add a 'test' step to run our test suite
    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // Per-module unit test suite (deterministic, no I/O dependencies)
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = unit_test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Test runner for tests/unit/
    const unit_runner_mod = b.createModule(.{
        .root_source_file = b.path("unit_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_runner = b.addTest(.{
        .root_module = unit_runner_mod,
    });
    const run_unit_runner = b.addRunArtifact(unit_runner);

    const unit_test_step = b.step("test-unit", "Run per-module unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);
    unit_test_step.dependOn(&run_unit_runner.step);

    const valgrind_test = b.addSystemCommand(&[_][]const u8{
        "--leak-check=full",
        "--show-leak-kinds=all",
        "--error-exitcode=1",
    });
    valgrind_test.addArtifactArg(tests);
    const test_valgrind_step = b.step("test-valgrind", "Run library tests with valgrind");
    test_valgrind_step.dependOn(&valgrind_test.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });

    b.installArtifact(bench_exe);

    // Run benchmark step
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("benchmark", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Valgrind benchmark step
    const valgrind_bench = b.addSystemCommand(&[_][]const u8{
        "valgrind",
        "--leak-check=full",
        "--show-leak-kinds=all",
        "--error-exitcode=1",
    });
    valgrind_bench.addArtifactArg(bench_exe);
    const bench_valgrind_step = b.step("benchmark-valgrind", "Run benchmarks with valgrind");
    bench_valgrind_step.dependOn(&valgrind_bench.step);

    // Tools
    const report_mod = b.createModule(.{
        .root_source_file = b.path("tools/benchmark_report.zig"),
        .target = target,
        .optimize = optimize,
    });

    const report_tool = b.addExecutable(.{
        .name = "benchmark_report",
        .root_module = report_mod,
    });

    // Benchmark report step
    const run_report = b.addRunArtifact(report_tool);
    run_report.addArtifactArg(bench_exe);

    const report_step = b.step("benchmark-report", "Run benchmarks and generate a comparison report");
    report_step.dependOn(&run_report.step);

    // Helper to create a flamegraph step
    const addFlamegraphStep = struct {
        fn add(builder: *std.Build, name: []const u8, output_name: []const u8, arg: []const u8, b_exe: *std.Build.Step.Compile, f_tool: *std.Build.Step.Compile) *std.Build.Step {
            const f_run_cmd = builder.addRunArtifact(f_tool);
            f_run_cmd.addArg(output_name);
            f_run_cmd.addArtifactArg(b_exe);
            f_run_cmd.addArg(arg);

            const step = builder.step(name, "Generate a flamegraph");
            step.dependOn(&f_run_cmd.step);
            return step;
        }
    }.add;

    const flamegraph_mod = b.createModule(.{
        .root_source_file = b.path("tools/flamegraph.zig"),
        .target = target,
        .optimize = optimize,
    });
    const flamegraph_tool = b.addExecutable(.{
        .name = "flamegraph_tool",
        .root_module = flamegraph_mod,
    });

    const all_step = addFlamegraphStep(b, "flamegraph-all", "flamegraph_all", "all", bench_exe, flamegraph_tool);
    const buffer_step = addFlamegraphStep(b, "flamegraph-buffer", "flamegraph_buffer", "buffer", bench_exe, flamegraph_tool);
    const btree_step = addFlamegraphStep(b, "flamegraph-btree", "flamegraph_btree", "btree", bench_exe, flamegraph_tool);
    const table_step = addFlamegraphStep(b, "flamegraph-table", "flamegraph_table", "table", bench_exe, flamegraph_tool);
    const parser_step = addFlamegraphStep(b, "flamegraph-parser", "flamegraph_parser", "parser", bench_exe, flamegraph_tool);
    const execution_step = addFlamegraphStep(b, "flamegraph-execution", "flamegraph_execution", "execution", bench_exe, flamegraph_tool);
    const transaction_step = addFlamegraphStep(b, "flamegraph-transaction", "flamegraph_transaction", "transaction", bench_exe, flamegraph_tool);
    const eviction_step = addFlamegraphStep(b, "flamegraph-eviction", "flamegraph_eviction", "eviction", bench_exe, flamegraph_tool);

    const flamegraphs_step = b.step("flamegraphs", "Generate all flamegraphs");
    flamegraphs_step.dependOn(all_step);
    flamegraphs_step.dependOn(buffer_step);
    flamegraphs_step.dependOn(btree_step);
    flamegraphs_step.dependOn(table_step);
    flamegraphs_step.dependOn(parser_step);
    flamegraphs_step.dependOn(execution_step);
    flamegraphs_step.dependOn(transaction_step);
    flamegraphs_step.dependOn(eviction_step);

    // Fuzz step
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = fuzz_mod,
    });
    b.installArtifact(fuzz_exe);
}
