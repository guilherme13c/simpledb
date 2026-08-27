# SimpleDB Project Brief

**SimpleDB** is a custom, lightweight, high-performance database engine built from scratch in Zig 0.16.0.

The project was created to explore and implement fundamental, low-level database primitives. Rather than relying on external libraries or OS-level page caches, SimpleDB implements its own storage abstractions. It features a complete custom storage hierarchy ranging from disk-level positional I/O up to a multi-threaded TCP server capable of handling concurrent queries, multi-version concurrency control (MVCC), distributed replication, and crash recovery.

### Key Capabilities

- **Storage Layer**: Custom 8KB page-based storage using `io_uring` for high-throughput, non-blocking I/O.
- **Buffer Pool**: Clock-Sweep (Second-Chance) eviction with concurrent prefetch and flush threads.
- **Indexing**: Unclustered B+Tree architecture with latch-crabbing for high concurrency and active node merging for efficient deletions.
- **Concurrency**: Multi-Version Concurrency Control (MVCC) with snapshot isolation, undo log construction, and non-blocking read access.
- **Durability**: Write-Ahead Log (WAL) implementing ARIES-style crash recovery (Analysis, Redo, Undo passes).
- **Query Execution**: Custom SQL subset (SELECT, INSERT, UPDATE, DELETE, CREATE/DROP/ALTER TABLE) with Volcano-style iterators, index and sequential scans, projection, filtering, aggregation (GROUP BY, COUNT, SUM, MIN, MAX, AVG), nested-loop and sort-merge joins, subqueries, CTEs, and window functions.
- **Interface**: Multi-threaded TCP server (`std.Io` event loops) exposing a SQL-like protocol; native CLI/REPL (`--cli`).
- **Distributed Systems**: Multi-Raft consensus, leader-follower logical replication via TCP WAL streaming, explicit joint consensus for safe topology changes (`RAFT_CONFIG_UPDATE`), consistent hashing sharding ring (Wyhash + virtual nodes), global wait-for graph gossip for distributed deadlock detection, and chaos testing harness.
- **Observability**: Benchmark suite with performance regression tracking (`zig build benchmark-report`), automated flamegraph profiling (`zig build flamegraphs`), and memory usage tracking via `DebugAllocator`.

### Core Objectives

- Deep dive into database storage architectures (Slotted Pages, B+Trees, Lazy Deletions, Active Node Merging).
- Implement performant, manual memory management (Buffer Pooling with Clock-Sweep eviction).
- Provide a robust concurrency model using Latch-Crabbing and Zig's non-blocking `std.Io` concurrency primitives.
- Expose a SQL-like TCP protocol for database interactions, parsed entirely via a custom Lexer and Parser.
- Ensure durability via a Logical Write-Ahead Log (WAL) with ARIES-style recovery.
- Scale horizontally via Leader-Follower logical replication and Multi-Raft consensus.
- Maintain high code quality: strict `std.Io` primitives, `packed struct` alignment, 8KB page limits, no external C libraries.

### Design Principles

- **Zig 0.16.0 Standard Library Only**: No external C libraries; all concurrency via `std.Io`.
- **Strict Memory Management**: Heavy reliance on `BufferManager` for caching; avoid dynamic allocation per query.
- **Data Integrity**: All page structures use `packed struct` for exact bit-widths; pages strictly 8KB; dirty flag always set on unpin.
- **Performance**: `io_uring` non-blocking I/O, concurrent prefetch/flush threads, latch-crabbing for minimal lock contention.
