# Testing Suite

SimpleDB utilizes Zig's built-in testing framework (`std.testing`) to validate its core primitives. Tests can be run from the root of the repository via:

```bash
zig build test
```

## What is Covered?

The testing suite focuses heavily on validating the correctness and thread-safety of the **bottom-up storage primitives**. Given the low-level nature of database engines, the foundation must be 100% correct before higher-level features (like SQL execution) can be safely tested.

1. **Storage Manager (`src/storage/storage_manager/storage_manager.zig`)**
   - **What:** Validates `io_uring` initialization, SQE submission, CQE completion loops, file creation, layout sizing (strict 8KB pages), and read/write integrity for single and multi-page requests.
   - **Why:** To ensure we aren't corrupting data blocks on disk and that the non-blocking event loop operates without dropping I/O completions.

2. **Buffer Manager (`src/storage/buffer_manager/buffer_manager.zig`)**
   - **What:** Tests the pinning/unpinning of frames, dirty flag updates, and the **Clock-Sweep Eviction Algorithm**. Ensures background `prefetch_thread` and `flusher_thread` synchronize safely with foreground readers/writers using the `io_uring` interface.
   - **Why:** Buffer management is the heart of SimpleDB's performance. Incorrect eviction leads to data loss or segmentation faults, and concurrency bugs would cause deadlocks.

3. **Page Layouts (`src/storage/page/slotted_view.zig`)**
   - **What:** Validates tuple insertions, dynamic resizing of slots, header integrity, and page compactions.
   - **Why:** Slotted pages are complex due to variable-length tuple records. We must test that inserting/deleting records doesn't overwrite adjacent slots or corrupt the 16-byte page header.

4. **B+Tree Indexing & Concurrency (`src/storage/index/btree.zig`, `btree_node.zig`)**
   - **What:** Node splits, **Active Node Merging**, key insertions, lazy/active deletions, range scans, and high-concurrency Latch-Crabbing via multi-threaded concurrent insertions.
   - **Why:** B+Trees have strict structural invariants. Node insertion/deletion logic and thread-safe crabbing are highly error-prone without isolated tests.

5. **Write-Ahead Log (`src/storage/wal/log_manager.zig`)**
   - **What:** Validates log appending, logical sequencing (LSNs), and flushing mechanisms.
   - **Why:** Durability and crash recovery depend completely on the WAL's sequence guarantees.

6. **Query Parser & Lexer (`src/query/lexer.zig`, `src/query/parser.zig`)**
   - **What:** Validates tokenization of SQL-like strings and the construction of Abstract Syntax Trees (ASTs).
   - **Why:** To ensure syntax errors are caught gracefully and that valid SQL produces the correct logical execution plan.

7. **High-Level Execution (`src/query/executor.zig`)**
   - **What:** Validates the Volcano-style iterators (SeqScan, IndexScan, NestedLoopJoin, SortMergeJoin, Aggregation) using in-memory live tables.
   - **Why:** Execution logic involves complex pipeline dependencies and data-type casting which needs regression testing.

8. **Concurrency Control / MVCC (`src/storage/concurrency/mvcc.zig`)**
   - **What:** Validates Multi-Version Concurrency Control (MVCC) isolation. Tests active transactions writing versions into the Undo Log, snapshot isolation guaranteeing repeatable reads for older transactions, and rollback operations restoring previous versions.
   - **Why:** Ensures transaction serializability and prevents readers from blocking writers (and vice-versa), while still guaranteeing consistent point-in-time reads.

9. **Secondary Indexes (`src/storage/catalog.zig`, `table.zig`)**
   - **What:** Tests dynamic creation of secondary indexes via `CREATE INDEX`, automatic synchronous indexing on `.insert` and `.delete`, and execution-layer point-lookup optimizations.
   - **Why:** Validates that adding new indexes properly backfills from heap data and that the query executor correctly leverages them over a sequential scan.

## What is NOT Covered (And Why)

1. **Network / TCP Server (`server.zig`)**
   - **Why:** Creating mock TCP clients and managing event-loop lifecycles in unit tests introduces network flakiness. The server is manually tested using the CLI/REPL pipe.
