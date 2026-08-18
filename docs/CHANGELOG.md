# Changelog

All notable changes to the SimpleDB project will be documented in this file.

## [Unreleased]

### Added
- **Extended Data Types**: Expanded schema support to include `Float` (f64), `Timestamp` (i64), `JSON` (String), `UUID` (16 bytes), and `Signed Integer` (i64) data types.
- **Advanced Query Features**: Added Aggregation support (`COUNT`, `SUM`, `MIN`, `MAX`, `AVG`) with `GROUP BY` using in-memory hash aggregation, as well as `Sort-Merge Join` logic.
- **CLI / REPL Shell**: Built a robust native command-line interface via `--cli`. Supports multi-line input and provides direct terminal-based interaction.
- **System SQL Capabilities**: Introduced a custom SQL subset with a Lexer, Parser, AST, and Volcano-style Executor (`src/query/`). Supports `SELECT`, `INSERT`, `DELETE`, `CREATE TABLE`, `DROP TABLE`, Sequential Scans, Index Scans, Projections, Filters, and Nested Loop Joins.
- **Transactions & ARIES Recovery**: Added a Write-Ahead Log (WAL) and recovery manager implementing physical ARIES-style recovery (Analysis, Redo, Undo passes), ensuring ACID compliance (`src/storage/wal/`).
- **Clock Sweep Buffer Manager**: Upgraded the buffer manager's replacement policy to use the Clock Sweep (Second-Chance) algorithm.
- **Performance Profiling**: Added automated flamegraph profiling capabilities and comprehensive benchmarking targets using Linux `perf` (`zig build flamegraphs`).
- **TCP Server**: Fully integrated non-blocking `std.Io` TCP server. Replaces single-threaded standard library sockets to support thousands of concurrent threads.
- **Catalog System**: Support for mapping string names to multiple distinct table objects. Includes thread-safe concurrency using lightweight atomic SpinLocks.
- **Commands**: Added text-protocol parsing for `CREATE`, `DROP`, `PUT`, `GET`, and `SCAN`.
- **Range Scans**: B+Tree leaf nodes now correctly link to their neighbors via a `next_leaf` pointer, allowing horizontal `O(N)` scans across the index.
- **Testing**: Built out a complete unit test and integration test suite encompassing disk layers, buffer pooling, and server logic. Integrated with Zig 0.16.0's `std.Build` system.
- **Frame Caching**: Added frame caching to `SeqScanExecutor` to avoid repeatedly fetching and unpinning the same heap page during sequential filter scans.

### Performance
- **Execution:** Improved `Executor Filter Scan` performance by ~35% (from ~48 ms to ~31 ms for 500k rows) by minimizing buffer manager page latch and hash table lookups during sequential scans on the same heap page.
### Changed
- **Zig Environment**: Upgraded system APIs to strictly match the Zig 0.16.0 standard library (`std.Io`, `std.Io.Mutex`, `std.Io.Dir`).
- **Buffer Pool Constraints**: Enforced 8KB page alignment and restricted metadata logic to use bitwise packing (`packed struct`) within the existing generic page header constraints.

### Fixed
- **Memory Leaks**: Ensured proper catalog teardown freeing table allocations on exit.
- **Alignment Crashes**: Corrected strict-alignment violations on unaligned pointers during node splits by enforcing explicit `@as(*align(1)...)` casting on `raw_page` offsets.
