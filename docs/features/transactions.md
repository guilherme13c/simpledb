# Transactions

SimpleDB provides a full-featured transaction system supporting ACID properties through a combination of **Write-Ahead Logging (WAL)**, **Multi-Version Concurrency Control (MVCC)** with **snapshot isolation**, and **undo logging** for reliable recovery.

## SQL Syntax

### Basic Transaction Commands

| Command | Description |
|---------|-------------|
| `BEGIN` | Starts a new transaction. All subsequent statements belong to this transaction until `COMMIT` or `ROLLBACK` is issued. |
| `COMMIT` | Makes all changes in the current transaction permanent. The transaction becomes durable. |
| `ROLLBACK` | Discards all changes made in the current transaction, restoring the database to its state before the transaction began. |
| `PREPARE` | Prepares a transaction for commit but does not make it durable yet. Useful for distributed transactions or early validation. |
| `EXPLAIN` | Shows the execution plan for a query without executing it. |

### Example Usage

```sql
BEGIN
    INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');
    INSERT INTO orders (user_id, amount) VALUES (1, 100.00);
    UPDATE accounts SET balance = balance - 100 WHERE id = 1;
    COMMIT

-- Or with prepare for distributed scenarios
PREPARE tx1;
BEGIN;
    -- ... transaction work ...
COMMIT;  -- or ROLLBACK
```

## ACID Guarantees

### Atomicity
Every transaction is either fully completed (all changes applied) or entirely rolled back. The system uses an **undo log** to track modifications, allowing rollback even after a crash.

### Consistency
SimpleDB enforces consistency through:
- **MVCC** – Each transaction operates on a consistent snapshot of the database at its start time.
- **Constraint enforcement** – Foreign keys, unique constraints, and check constraints are validated before commit.
- **Isolation levels** – By default, SimpleDB uses **snapshot isolation**, which prevents dirty reads, non-repeatable reads, and phantom reads.

### Isolation (Snapshot Isolation)
- Each transaction receives a unique `txn_id` and a starting LSN (Log Sequence Number).
- Readers see a consistent snapshot of the database as it existed at their start time.
- Writers create new versioned rows; older versions remain readable until the transaction commits.
- This eliminates the need for explicit locking for reads, improving concurrency.

### Durability
Changes are never written to the main storage until they are safely recorded in the **Write-Ahead Log (WAL)**. The WAL is flushed to disk before `COMMIT` is acknowledged, ensuring that committed transactions survive crashes.

## MVCC & Visibility

### How MVCC Works

1. **Snapshot Creation** – When `BEGIN` is called, a snapshot is taken with a unique `txn_id` and `prev_lsn` (the LSN of the last committed transaction before the snapshot).
2. **Versioned Rows** – Every write creates a new version of a row with a higher LSN than the previous version. Old versions remain accessible for readers of older snapshots.
3. **Visibility Rules** – A row version is visible to a transaction if:
   - Its LSN ≥ the transaction's `prev_lsn`,
   - And the transaction's snapshot was created before or at the same time as the row's creation.
4. **Garbage Collection** – Old versions are cleaned up when no active snapshot can still see them.

### Example

```
LSN | Action          | Version
-----|---------------|----------
100 | CREATE TABLE   | T1
105 | INSERT (a)     | V1
110 | INSERT (b)     | V2
115 | UPDATE (a)     | V3
120 | COMMIT         | —
130 | SELECT (a)     | V3 (latest version visible)
```

## Crash Recovery (ARIES)

SimpleDB implements the **ARIES** recovery algorithm in three passes:

### 1. Analysis Pass
- Scans the WAL from the last checkpoint forward to identify:
  - **Active transactions** (those not committed or rolled back)
  - **Modified pages** (pages with unflushed changes)
  - **Dirty pages** requiring redo
- Builds a transaction table and a dirty-page table.

### 2. Redo Pass
- Reapplies all logged changes from the WAL to bring the database to the state at the moment of the crash.
- Only pages with unflushed changes are redone.
- Ensures durability of committed transactions.

### 3. Undo Pass
- Rolls back all uncommitted transactions using the **undo log**.
- The undo log contains `UndoOp` records for deletions and insertions:
  - `delete_key` – records the key of deleted rows (used for rollback)
  - `insert_key` – records the key of inserted rows (used for compensating actions)
- Transactions are processed in reverse order of their commit sequence.

### Recovery Flow

```
Crash occurs → System starts recovery
    │
    ├─ Analysis: Determine active transactions & dirty pages
    │
    ├─ Redo: Replay all committed changes from WAL
    │
    └─ Undo: Rollback uncommitted transactions via undo log
```

## Undo Log

The undo log is stored in the WAL and is used during recovery and rollback:

- **Delete Operations** – When a row is deleted, the system records a `delete_key` containing the row's key and the LSN of the deletion.
- **Insert Operations** – When a new row is inserted, the system records an `insert_key` containing the key and the LSN of the insertion.
- **Compensation** – During rollback, the undo log is traversed backward, removing or correcting the effects of incomplete transactions.

## Write-Ahead Logging (WAL)

### Purpose
WAL ensures that committed transactions are durably written before the transaction is considered complete.

### Structure
Each WAL record contains:
- `txn_id` – Identifier of the originating transaction
- `prev_lsn` – LSN of the last committed transaction before this one
- `record_type` – `insert_tuple`, `delete_tuple`, `update_page_meta`, `checkpoint`
- `page_id` – Target page(s) affected
- `offset` – Physical offset in the page where the change was made
- `payload` – The actual data (row values, delta information)

### Flushing
- Before `COMMIT`, the system forces the WAL to disk (fsync) to guarantee durability.
- The `log_manager` tracks the current LSN and flushes pages whose dirty LSN is ≤ the current LSN.

## Deadlock Handling

SimpleDB prevents deadlocks through a **global rwlock** and per-resource lock queues:

1. **Resource Acquisition** – When a transaction acquires a lock on a resource, it is added to a queue.
2. **Cycle Detection** – Before granting a lock, the system checks for cycles in the lock queue using DFS.
3. **Deadlock Resolution** – If a cycle is detected, the transaction with the highest `txn_id` (or lowest priority) is aborted.
4. **Abort Propagation** – Aborted transactions are marked as such and their undo logs are discarded.

## Savepoints

SimpleDB currently does not expose explicit savepoints. Instead, transactions are atomic units:
- A `ROLLBACK` always reverts the entire transaction to its pre-transaction state.
- There is no partial rollback capability within a transaction.
- For long-running transactions, consider breaking them into smaller logical units or using `PREPARE` followed by manual commit/rollback.

## Summary

| Feature | Implementation |
|---------|----------------|
| Transaction control | `BEGIN`, `COMMIT`, `ROLLBACK`, `PREPARE`, `EXPLAIN` |
| ACID | Atomicity via undo log, Consistency via MVCC + constraints, Isolation via snapshot isolation, Durability via WAL |
| MVCC | Snapshot isolation with versioned rows; readers see consistent snapshots |
| Recovery | ARIES (Analysis → Redo → Undo) |
| Undo log | Stores delete/insert keys for rollback |
| WAL | Write-ahead log with LSN ordering; forced before commit |
| Deadlocks | Cycle detection in lock queues; highest txn_id aborted |
| Savepoints | Not supported; full transaction rollback only |
