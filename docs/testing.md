# Testing Suite

SimpleDB utilizes Zig's built-in testing framework (`std.testing`) to validate its core primitives, complemented by a Python integration test suite for end-to-end validation. Tests can be run from the root of the repository via:

## Unit Tests

```bash
zig build test
```

## Integration Tests

```bash
./run_all_tests.sh
```

## What is Covered?

The testing suite focuses heavily on validating the correctness and thread-safety of the **bottom-up storage primitives**. Given the low-level nature of database engines, the foundation must be 100% correct before higher-level features (like SQL execution) can be safely tested.

### 1. Storage Manager (`src/storage/storage_manager/storage_manager.zig`)

- **What:** Validates `io_uring` initialization, SQE submission, CQE completion loops, file creation, layout sizing (strict 8KB pages), and read/write integrity for single and multi-page requests.
- **Why:** To ensure we aren't corrupting data blocks on disk and that the non-blocking event loop operates without dropping I/O completions.

### 2. Buffer Manager (`src/storage/buffer_manager/buffer_manager.zig`)

- **What:** Tests the pinning/unpinning of frames, dirty flag updates, and the **Clock-Sweep Eviction Algorithm**. Ensures background `prefetch_thread` and `flusher_thread` synchronize safely with foreground readers/writers using the `io_uring` interface.
- **Why:** Buffer management is the heart of SimpleDB's performance. Incorrect eviction leads to data loss or segmentation faults, and concurrency bugs would cause deadlocks.

### 3. Page Layouts (`src/storage/page/slotted_view.zig`)

- **What:** Validates tuple insertions, dynamic resizing of slots, header integrity, and page compactions.
- **Why:** Slotted pages are complex due to variable-length tuple records. We must test that inserting/deleting records doesn't overwrite adjacent slots or corrupt the 16-byte page header.

### 4. B+Tree Indexing & Concurrency (`src/storage/index/btree.zig`, `btree_node.zig`)

- **What:** Node splits, **Active Node Merging**, key insertions, lazy/active deletions, range scans, and high-concurrency Latch-Crabbing via multi-threaded concurrent insertions.
- **Why:** B+Trees have strict structural invariants. Node insertion/deletion logic and thread-safe crabbing are highly error-prone without isolated tests.

### 5. Write-Ahead Log (`src/storage/wal/log_manager.zig`)

- **What:** Validates log appending, logical sequencing (LSNs), and flushing mechanisms.
- **Why:** Durability and crash recovery depend completely on the WAL's sequence guarantees.

### 6. Query Parser & Lexer (`src/query/lexer.zig`, `src/query/parser.zig`)

- **What:** Validates tokenization of SQL-like strings and the construction of Abstract Syntax Trees (ASTs).
- **Why:** To ensure syntax errors are caught gracefully and that valid SQL produces the correct logical execution plan.

### 7. High-Level Execution (`src/query/executor.zig`)

- **What:** Validates the Volcano-style iterators (SeqScan, IndexScan, NestedLoopJoin, SortMergeJoin, Aggregation) using in-memory live tables.
- **Why:** Execution logic involves complex pipeline dependencies and data-type casting which needs regression testing.

### 8. Concurrency Control / MVCC (`src/storage/concurrency/mvcc.zig`)

- **What:** Validates Multi-Version Concurrency Control (MVCC) isolation. Tests active transactions writing versions into the Undo Log, snapshot isolation guaranteeing repeatable reads for older transactions, and rollback operations restoring previous versions.
- **Why:** Ensures transaction serializability and prevents readers from blocking writers (and vice-versa), while still guaranteeing consistent point-in-time reads.

### 9. Secondary Indexes (`src/storage/catalog.zig`, `table.zig`)

- **What:** Tests dynamic creation of secondary indexes via `CREATE INDEX`, automatic synchronous indexing on `.insert` and `.delete`, and execution-layer point-lookup optimizations.
- **Why:** Validates that adding new indexes properly backfills from heap data and that the query executor correctly leverages them over a sequential scan.

## Integration Testing (Python Suite)

We have a comprehensive integration testing suite written in Python (`tests/integration/`) that connects to the database server over TCP. This ensures end-to-end correctness.

**What the integration suite covers:**

- **TCP Server (`server.zig`)**: Validates that the event-loop lifecycle, connection handling, and client-server protocol work flawlessly.
- **ACID Properties (`test_properties.py`, `test_crash_recovery.py`)**: Tests read-your-writes, concurrent transaction isolation (repeatable reads), lock timeouts, and uncommitted transaction ARIES undo-pass recovery.
- **Advanced SQL (`test_full_sql.py`, `test_outer_join.py`, `test_subquery.py`, `test_cte.py`)**: End-to-end tests for JOINs, CTEs, Window functions, aggregations, Subqueries, and GROUP BY.
- **Buffer Pool Behavior (`test_buffer_pool.py`)**: Forcibly exceeds memory thresholds to trigger the clock-sweep eviction logic and prove that dirty pages flush to disk without corruption.
- **Concurrency Edge Cases (`test_concurrency_edge_cases.py`)**: Ensures that deadlocks are safely detected and aborted, and that concurrent inserts/updates on the exact same row don't lose data.

## Test Organization

### Unit Tests (`src/tests/`)

- `test_wfg.zig` – Wait-for graph (deadlock detection)
- `test_undo.zig` – Undo log / MVCC rollback
- `test_transaction.zig` – Transaction lifecycle
- `test_slotted_view.zig` – Slotted page operations
- `test_replication.zig` – Logical WAL replication
- `test_raft_config.zig` – Multi-Raft joint consensus
- `test_raft.zig` – Raft leader election
- `test_parser.zig` – SQL parser
- `test_log_record.zig` – WAL records
- `test_lexer.zig` – Tokenization
- `test_hash_index.zig` – Hash index lookups
- `test_gossip.zig` – Gossip protocol
- `test_executor_pipeline.zig` – Volcano iterators
- `test_connection.zig` – TCP server connections

### Integration Tests (`tests/integration/`)

- `test_sharding.py` – Consistent hash sharding
- `test_replication_consistency.py` – Leader-follower state consistency
- `test_raft_election.py` – Raft leader election over TCP
- `test_properties.py` – ACID properties
- `test_outer_join.py` – OUTER JOIN semantics
- `test_window.py` – Window functions
- `test_subquery.py` – Subqueries
- `test_cte.py` – Common table expressions
- `test_buffer_pool.py` – Buffer pool eviction under pressure
- `test_scatter_gather.py` – Multi-shard query routing
- `test_replication.py` – Logical replication end-to-end
- `test_update.py` – UPDATE operations
- `test_server.py` – TCP server lifecycle
- `test_full_sql.py` – Full SQL coverage
- `test_explain.py` – EXPLAIN query plans
- `test_crash_recovery.py` – ARIES crash recovery
- `test_concurrency_edge_cases.py` – Deadlock detection

### Chaos Tests (`tests/chaos_test*.py`)

- `chaos_test.py` – Network partition chaos
- `chaos_test2.py` – Extended chaos scenarios
- `chaos_test_log.py` – WAL corruption recovery

## Adding New Tests

1. **Unit test**: Add a `.zig` file in `src/tests/`, reference it in `src/unit_tests.zig` and `src/tests.zig`
2. **Integration test**: Add a `.py` file in `tests/integration/` and reference it in `run_all_tests.sh`
3. **Run locally**: `zig build test` for units, `./run_all_tests.sh` for integration
