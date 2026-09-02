# Implementation reference

This directory describes the code that is in this repository, not a target
architecture. It was verified against commit `4d6839880c733b600e394eff7e91bd8a81d4795c`
on 2026-09-02. When behaviour and documentation differ, the Zig source and
tests are authoritative.

## Map of the implementation

| Area | Main source | Details |
| --- | --- | --- |
| SQL front end | `src/query/{lexer,parser,ast}.zig` | `query/` |
| Execution | `src/query/executor.zig`, `src/query/executor/` | `query/executor.md` |
| Tables and indexes | `src/storage/{table,catalog,in_memory_table}.zig`, `src/storage/index/` | `storage/` |
| Pages, cache, and I/O | `src/storage/page/`, `buffer_manager/`, `storage_manager/` | `storage/page_layouts.md`, `buffer_manager.md`, `storage_manager.md` |
| Transactions and logging | `src/storage/wal/`, `src/storage/concurrency/` | `storage/transaction.md`, `wal.md`, `recovery.md`, `concurrency/` |
| TCP server | `src/server/{server,connection,execution,undo}.zig` | `server/` |
| Cluster experiments | `src/server/{gossip,raft,raft_config,replication,consistent_hash}.zig` | `distributed/` |

## Important implementation boundaries

- Pages, catalog metadata, and B-tree structures are persisted. Secondary
  indexes, table tuple counts, and the heap-page cursor are rebuilt or reset in
  memory; index definitions themselves are not catalog-persistent.
- The B+tree supports duplicate keys and range scans. Deletion removes an empty
  child from its parent, but does **not** redistribute or merge underfull
  siblings and does not reclaim pages.
- MVCC is an eight-byte `(xmin, xmax)` tuple prefix plus snapshot visibility.
  There are no version chains, vacuum, commit-status table, or physical undo.
- WAL serializes appends and can force the file, but normal `COMMIT` does not
  force a WAL flush. Recovery builds ATT/DPT and advances page LSNs only; it
  does not replay or undo tuple bytes. This is not crash-safe ARIES.
- The cluster code is experimental: gossip is unauthenticated UDP, Raft has
  leader election and partial config serialization but no durable Raft state or
  committed log, and replication applies only logical insert/delete records.

Each page records its source module and calls out these limits where they affect
the documented feature.
