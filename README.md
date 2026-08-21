# SimpleDB

**SimpleDB** is a custom, lightweight, high-performance database engine built from scratch in Zig 0.16.0.

It explores fundamental, low-level database primitives by implementing its own storage abstractions instead of relying on external libraries or OS-level page caches. SimpleDB supports advanced features like Multi-Version Concurrency Control (MVCC), io_uring asynchronous I/O, ARIES crash recovery, and Leader-Follower logical replication for horizontal read scaling.

## Documentation
- [Advanced SQL Features](docs/features/advanced_sql.md)
The documentation has been split into several focused guides:

1. **[Project Brief](docs/brief.md)** - High-level overview and core objectives of the database project.
2. **[Architecture Overview](docs/architecture.md)** - A detailed breakdown of the internal systems (Storage, Buffer Pool, Indexing, Catalog, Query Parser, etc.).
3. **[Testing Suite](docs/testing.md)** - Overview of the `zig build test` coverage, what is tested, and what is currently untested (with justifications).
4. **[Profiling and Benchmarking](docs/profiling_and_benchmarking.md)** - Comprehensive guide to using the `zig build benchmark-report` feature and generating visual flamegraphs via `zig build flamegraphs`.

## Getting Started
Requirements:
- Linux
- Zig 0.16.0
- `perf` (linux-tools) for profiling

**Running Unit Tests:**
```bash
zig build test
```

**Running Integration Tests (Network, MVCC & ACID compliance):**
```bash
# You can run the entire integration test suite (with proper timeout and lifecycle management):
./run_all_tests.sh

# Or you can run an individual Python integration test:
zig build
python3 tests/integration/test_server.py
```

**Running CBO Benchmarks:**
```bash
python3 benchmarks/bench_optimizer.py
```

**Running Fuzzing (AFL++):**
```bash
# Uses QEMU mode over the native binary
zig build fuzz
mkdir -p fuzz_in; echo "SELECT * FROM sys_tables;" > fuzz_in/seed1.sql
afl-fuzz -Q -i fuzz_in -o fuzz_out -- ./zig-out/bin/fuzz
```

**Running Benchmark Report:**
```bash
zig build benchmark-report
```

**Generating Flamegraphs:**
```bash
zig build flamegraphs
```
- [Distributed Systems](docs/distributed_systems.md)
