# Profiling and Benchmarking

Performance is a first-class feature of SimpleDB. To ensure we don't introduce performance regressions when modifying the core storage tier, SimpleDB comes with a comprehensive benchmarking suite integrated natively into the Zig build system.

## Benchmarks

The benchmark suite tests various layers of the database (from the buffer pool to query execution).

To run the suite and generate a comparison report, run:

```bash
zig build benchmark-report
```

### What does the Report do?
The `benchmark-report` command compiles the benchmark executable, runs it, and parses its metric output. 
It then compares the current metrics against the previous run cached at `.benchmark_cache/latest.json`. 

The output simulates a `cargo bench` or `criterion`-like table, indicating whether performance has improved, regressed, or if the change is within the threshold of noise (+/- 5.0%):

```text
================ BENCHMARK REPORT ================
Benchmark                                | Time (ms)       | Change              
--------------------------------------------------------------------------------
Transaction & WAL (100k commits)         | 109588          | N/A
BTree Insert (10M records)               | 3001            | -2.53% (No change in performance detected - noise)
Sequential Fetch & Pin (100k pages, 50x) | 40662           | +5.79% (Performance has regressed)
Table Search (2M records, 2x)            | 1058            | -13.42% (Performance has improved)
==================================================
```

### Available Benchmarks
The suite covers the following modules:
1. **Buffer Manager:** Tests `fetch_frame` and `unpin_frame` loops over a small pool size to intentionally trigger high contention and IO blocking.
2. **Buffer Eviction:** Tests the performance of the **Clock-Sweep** eviction algorithm directly.
3. **BTree:** Tests insertions and recursive node searches over millions of elements.
4. **Table:** Tests end-to-end tuple serializations and page slot management.
5. **Parser:** Validates the speed of tokenization and AST generation over complex nested SQL queries.
6. **Execution:** Tests Volcano-model iterator speeds over simulated raw datasets.
7. **Transaction & WAL:** Tests commit latency by repeatedly appending records and flushing the log manager.

## Profiling (Flamegraphs)

To identify CPU bottlenecks, SimpleDB wraps Linux `perf` tools directly into the Zig build system to generate interactive SVG flamegraphs.

### Requirements
- Linux OS
- `perf` command-line tool (`apt install linux-tools-common linux-tools-generic`)

### Generating Flamegraphs

Run the following command to profile the codebase:

```bash
zig build flamegraphs
```

This step compiles the benchmarks and uses `tools/flamegraph.zig` to:
1. Run `perf record -F 999 -g` dynamically against each benchmark (saving to unique outputs like `perf_buffer.data` to allow parallel executions).
2. Download Brendan Gregg's `stackcollapse-perf.pl` and `flamegraph.pl` scripts if they don't already exist.
3. Pipe the `perf script` output through the perl scripts to generate `.svg` files.

The output will be placed in the `profiling/` directory:
- `profiling/flamegraph_all.svg` (All benchmarks)
- `profiling/flamegraph_buffer.svg`
- `profiling/flamegraph_btree.svg`
- `profiling/flamegraph_table.svg`
- `profiling/flamegraph_eviction.svg`
- `profiling/flamegraph_execution.svg`
- `profiling/flamegraph_parser.svg`
- `profiling/flamegraph_transaction.svg`

Open any of these SVG files in your web browser to interactively explore where CPU time is being spent in the database stack!
