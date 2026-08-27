# SimpleDB

**SimpleDB** is a custom, lightweight, high-performance database engine built from scratch in Zig 0.16.0.

The project was created to explore and implement fundamental, low-level database primitives. Rather than relying on external libraries or OS-level page caches, SimpleDB implements its own storage abstractions. It features a complete custom storage hierarchy ranging from disk-level positional I/O up to a multi-threaded TCP server capable of handling concurrent queries, multi-version concurrency control (MVCC), distributed replication, and crash recovery.

## Technical Summary

SimpleDB follows a layered architecture that separates storage, memory, indexing, and networking concerns. Each layer is implemented in Zig 0.16.0 using only `std.Io` primitives for I/O and concurrency, ensuring maximum control over performance and determinism.

### Layers

1. **Storage Manager** (`src/storage/storage_manager.zig`) – Uses `io_uring` for asynchronous, non-blocking I/O directly with the Linux kernel.
2. **Buffer Manager** (`src/storage/buffer_manager/buffer_manager.zig`) – Manages a fixed-size pool of 4096 8KB pages with Clock-Sweep eviction, concurrent prefetch, and flush threads.
3. **Page Layouts** (`src/storage/page/`) – Slotted pages (variable-length tuples) and B+Tree index pages, both with 16-byte packed headers.
4. **Indexing** (`src/storage/index/`) – Unclustered B+Tree with latch-crabbing for high concurrency and active node merging for efficient deletions.
5. **Table & Catalog** (`src/storage/table.zig`, `src/storage/catalog.zig`) – Logical tier coupling B+Tree indexes with slotted pages, supporting secondary indexes and MVCC.
6. **Query Parser & Execution** (`src/query/`) – Custom SQL subset with hand-written lexer, recursive-descent parser, and Volcano-style iterator execution.
7. **Interface & Replication** (`src/server/`) – Multi-threaded TCP server, ARIES WAL, and leader-follower logical replication.

### Features

- **Storage**: 8KB fixed-size pages with 16-byte packed headers; slotted layout for variable-length tuples; B+Tree indexes (primary and secondary); Clock-Sweep buffer management.
- **Concurrency**: Latch-crabbing for high-concurrency reads; Multi-Version Concurrency Control (MVCC) for lock-free reads with snapshot isolation; active node merging for space efficiency.
- **Persistence**: Write-Ahead Log (WAL) implementing ARIES-style crash recovery (Analysis, Redo, Undo passes).
- **Distributed**: Multi-Raft consensus for leader election and replication; leader-follower logical replication via TCP WAL streaming; explicit joint consensus for safe topology changes; global wait-for graphs via gossip for distributed deadlock detection; consistent hashing (Wyhash + virtual nodes) for sharding.
- **Querying**: Custom SQL subset with cost-based optimizer (scan cost, index selectivity); Volcano iterator execution (sequential/index scans, projections, filters, hash aggregation, sort-merge/nested-loop joins, subqueries, CTEs, window functions).
- **Observability**: Comprehensive benchmark suite with performance regression tracking (`zig build benchmark-report`); automated flamegraph profiling with `perf` (`zig build flamegraphs`); memory usage tracking via `DebugAllocator`.

## Getting Started

### Requirements

- Linux
- Zig 0.16.0
- `perf` (linux-tools) for profiling

### Build & Test

```bash
# Build the project
zig build

# Run unit tests
zig build test

# Run integration tests (network, MVCC, ACID compliance)
./run_all_tests.sh

# Run individual integration test
zig build
python3 tests/integration/test_server.py
```

### Benchmarking & Profiling

```bash
# Run cost-based optimizer benchmarks
python3 benchmarks/bench_optimizer.py

# Run benchmark reports with regression detection
zig build benchmark-report

# Run fuzzing (AFL++ QEMU mode)
zig build fuzz
mkdir -p fuzz_in; echo "SELECT * FROM sys_tables;" > fuzz_in/seed1.sql
afl-fuzz -Q -i fuzz_in -o fuzz_out -- ./zig-out/bin/fuzz

# Generate flamegraph SVGs for CPU profiling
zig build flamegraphs
```

## Documentation

- [Advanced SQL Features](docs/features/querying.md)
- [Architecture Overview](docs/architecture.md)
- [Testing Suite](docs/testing.md)
- [Profiling and Benchmarking](docs/profiling_and_benchmarking.md)
- [Distributed Systems](docs/distributed_systems.md)
- [Non-Negotiables & Engineering Principles](docs/non-negotiables.md)
- [Project Brief](docs/brief.md)

## Design Principles

Strict Zig 0.16.0 implementation using only `std.Io` primitives for I/O and concurrency; `packed struct` alignment for exact bit-widths in page layouts; manual memory management with buffer pool caching; deterministic performance characteristics; no external C library dependencies.