# Profiling and Benchmarking SimpleDB

SimpleDB includes a built-in benchmarking suite and automated scripts for generating flamegraphs using `perf`. This documentation outlines how to run the benchmarks, generate profiling data, and interpret the results to optimize the system.

## Benchmarks

The benchmarking suite is located in `src/benchmark.zig` and contains stress tests for the core components of the database:
- **Buffer Manager Benchmark**: Evaluates the latency and throughput of fetching and pinning pages sequentially under heavy concurrent simulation.
- **B-Tree Benchmark**: Simulates high-throughput indexing by inserting and searching millions of records in the B-Tree index.
- **Table Benchmark**: Evaluates heap page allocations, tuple insertions, and unindexed full-table scans.

### Running Benchmarks

You can run the benchmarks using the Zig build system. The benchmarks run in `ReleaseFast` mode to accurately represent production performance.

To run all benchmarks:
```bash
zig build benchmark
```

To run a specific benchmark, you can pass arguments to the benchmark runner:
```bash
# Run only the Buffer Manager benchmarks
zig build benchmark -- buffer

# Run only the B-Tree benchmarks
zig build benchmark -- btree

# Run only the Table benchmarks
zig build benchmark -- table
```

## Profiling with Flamegraphs

To help identify performance bottlenecks, SimpleDB provides a seamless integration with Brendan Gregg's FlameGraph tools. When a flamegraph target is built, it automatically samples the execution of the benchmark using Linux's `perf record` (at 999Hz) and generates an SVG flamegraph.

The generated SVG files are automatically organized and saved in the `profiling/` directory.

### Generating Flamegraphs

You can generate flamegraphs for individual benchmarks or for the entire system at once.

To generate all flamegraphs:
```bash
zig build flamegraphs
```
This command runs all the individual profiling targets and populates the `profiling/` directory with the following files:
- `profiling/flamegraph_all.svg`
- `profiling/flamegraph_buffer.svg`
- `profiling/flamegraph_btree.svg`
- `profiling/flamegraph_table.svg`

Alternatively, you can generate a flamegraph for a specific subsystem:
```bash
zig build flamegraph-buffer
zig build flamegraph-btree
zig build flamegraph-table
```

### Navigating the Flamegraph

1. **Open the SVG**: Open any generated `.svg` file in a web browser (e.g., Chrome, Firefox).
2. **Read Bottom-Up**: The y-axis represents the stack depth. The lowest bars represent the entry points (e.g., `main`), and the highest bars represent the functions currently executing on the CPU.
3. **Width = Time**: The x-axis does not represent the passage of time; it represents the population of samples. The wider the bar, the more time the CPU spent in that function (or its children).
4. **Interactive Search**: Click on any bar to zoom into that call stack. You can also press `Ctrl+F` to search for specific function names.

### Common Profiling Scenarios

- **High Locking Overhead**: If functions like `lockShared` or `lockUncancelable` dominate the width of the graph, the system is suffering from high lock contention. Consider finer-grained locking or reducing the frequency of lock acquisitions.
- **Buffer Pool Misses**: If a large portion of time is spent in `fetch_frame` waiting on `write_page` or `read_page`, it indicates heavy disk I/O. Tuning the buffer pool size or optimizing the clock sweep algorithm can mitigate this.
- **Redundant Memory Operations**: Look out for wide bars in functions like `memcpy`, `memmove`, or hash map lookups. Optimizing these paths (e.g., using SIMD or avoiding the hash map lookups by directly referencing `Frame` structures) often yields massive performance gains.
