# Lock Manager Design

## Overview

The **Lock Manager** is the central coordination component for concurrent access to storage resources in Simpledb. It provides fine‑grained locking primitives (shared vs. exclusive), manages lock queues per resource, and integrates with the **Wait‑For Graph (WFG)** for deadlock detection and victim selection.

## Lock Types

| Mode | Description |
|------|-------------|
| `shared` | Multiple transactions may hold a shared lock simultaneously. Read‑only or concurrent read access. |
| `exclusive` | At most one transaction may hold an exclusive lock. Guarantees mutual exclusion for writes or exclusive read‑modify‑write operations. |

Locks are associated with a `resource_id` (typically a hash of a table + key pair). Each resource maintains its own queue of pending lock requests.

## Granularity

- **Row‑level**: Individual rows within a table can be locked independently.
- **Page‑level**: Entire pages (e.g., 4 KB chunks) are locked together for coarse‑grained concurrency.
- **Table‑level**: The whole table can be locked (used during bulk operations).

The choice depends on the workload: high‑contention hot rows benefit from row‑level locking; large‑scale scans benefit from page‑level or table‑level locks.

## Upgrade/Downgrade

- **Shared → Exclusive**: When a transaction acquires an exclusive lock on a resource it already holds a shared lock on, the lock is upgraded atomically. This is safe because no other transaction currently holds the exclusive version.
- **Exclusive → Shared**: An exclusive lock cannot be downgraded; attempting to upgrade to shared when another transaction holds the exclusive lock results in a deadlock‑detection path.

## Timeouts & Fairness

- **Acquisition timeout**: `lock_shared` and `lock_exclusive` loop with a configurable timeout (≈10 s) before giving up. If the timeout is exceeded, the transaction is considered deadlocked.
- **Retry limit**: Up to 100 acquisition attempts are permitted before the lock manager assumes a deadlock and aborts the offending transaction.
- **Fairness**: The queue is FIFO per resource. Upgrade logic preserves the order of existing requests, ensuring that a transaction that arrived earlier gets priority when upgrading.

## Deadlock Detection via Wait‑For Graph

Deadlocks are detected by constructing a **Wait‑For Graph (WFG)** that records every wait‑for relationship between transactions and resources. A cycle in this graph indicates a deadlock.

### Data Structures

- **Lock Queue** – per‑resource FIFO queue of pending lock requests (each entry contains `txn_id`, `mode`, `granted`).
- **Transaction Tracking** – `txn_locks` maps `txn_id → [resource_id...]` for fast release on abort/commit.
- **Wait‑For Graph** – global `Edge` objects linking a `waiting` transaction to a `holding` transaction.

### Cycle Detection Algorithm

The WFG uses a classic depth‑first search (DFS) with three states per node:
- **White** – unvisited
- **Gray** – currently on recursion stack (in progress)
- **Black** – fully processed

A cycle is found when the DFS encounters a gray node again. The cycle root is returned as the offending transaction.

## MVCC Interaction

Simpledb employs **Multi‑Version Concurrency Control (MVCC)** for snapshot isolation. The lock manager coordinates with MVCC as follows:

1. **Read‑only transactions** acquire only `shared` locks. They never block writers but must still respect the WFG for deadlock avoidance.
2. **Write‑intention locks** (`exclusive`) are acquired before performing any modifications. The lock ensures that the transaction sees a consistent snapshot and prevents phantom reads.
3. **Upgrade from shared → exclusive** is safe because the exclusive lock implicitly invalidates any older snapshots that might have been taken while the shared lock was held.
4. **Abort/Commit handling**: When a transaction is aborted or committed, its locks are released via `unlock_all` or `unlock`. The WFG edges are removed accordingly, allowing other transactions to proceed.

## API Summary

| Function | Purpose |
|----------|----------|
| `lock_shared(txn_id, resource_id)` | Acquire a shared lock (with deadlock detection) |
| `lock_exclusive(txn_id, resource_id)` | Acquire an exclusive lock (with upgrade support) |
| `unlock(txn_id, resource_id)` | Release a lock and wake waiters |
| `kill_transaction(txn_id)` | Mark a transaction as dead; notifies waiters |
| `get_wait_for_edges(list)` | Extract wait‑for edges for WFG construction |
| `can_grant_lock(queue, txn_id, mode)` | Determine if a lock can be granted (used internally) |

## Integration with Wait‑For Graph

When a transaction waits for a lock that is held by another transaction, the WFG records an edge `(waiting_txn → holding_txn)`. Periodically (or on demand), the WFG is scanned for cycles. If a cycle is found, the transaction(s) involved are marked as deadlocked and are candidates for victim selection.

## Distributed Considerations

In a cluster deployment, the WFG can be replicated across nodes using **gossip propagation**. Each node maintains a local subgraph; periodic gossip exchanges merge edges and propagate deadlock information. This enables distributed deadlock detection without a single point of failure.

---

*Documentation generated from `src/storage/concurrency/lock_manager.zig` and `src/storage/concurrency/wfg.zig`*
