# ARIES Recovery Manager

## Overview
The `RecoveryManager` implements the **ARIES** (Algorithms for Recovery and Isolation Exploiting Semantics) recovery algorithm. It runs at database startup to bring the system to a consistent state after a crash.

Source: `src/storage/wal/recovery_manager.zig`

## Data Structures

### Active Transaction Table (ATT)
```zig
att: std.AutoHashMap(u32, u32)  // txn_id -> last_lsn
```
Tracks all transactions that were active at the time of crash. Maps each transaction ID to the LSN of its most recent log record.

### Dirty Page Table (DPT)
```zig
dpt: std.AutoHashMap(u32, u32)  // page_id -> rec_lsn
```
Tracks pages that had modifications not yet flushed to disk at crash time. Maps each page ID to the **recLSN** — the LSN of the first log record that dirtied the page after it was last flushed.

## Three Passes

### Pass 1: Analysis Pass
**Purpose**: Reconstruct ATT and DPT by scanning the WAL from beginning (or last checkpoint).

```zig
fn analysis_pass(self: *RecoveryManager) !void
```

**Algorithm**:
1. Start at offset 0 (or checkpoint LSN if implemented)
2. Read each log record header sequentially
3. For each record:
   - **Commit/Abort**: Remove txn from ATT (transaction completed)
   - **Other types (except checkpoint)**: Add/update txn in ATT with this LSN
   - **Data modification records** (`insert_tuple`, `delete_tuple`, `update_page_meta`):
     - If page not in DPT, add with this record's LSN as recLSN

**Corruption Handling**: If header.lsn != file offset, log warning and stop scanning.

### Pass 2: Redo Pass
**Purpose**: Reapply all changes from uncommitted and committed transactions that may not have reached disk.

```zig
fn redo_pass(self: *RecoveryManager) !void
```

**Algorithm**:
1. Find `min_rec_lsn` = minimum recLSN in DPT (earliest dirty page)
2. Scan WAL from `min_rec_lsn` to end
3. For each modification record (`insert_tuple`, `delete_tuple`, `update_page_meta`):
   - If page in DPT AND record.lsn >= page's recLSN:
     - Fetch page from buffer manager
     - If page.lsn < record.lsn → **needs redo**
     - Set page.lsn = record.lsn
     - Mark page dirty (unpin with `dirty=true`)

**Note**: Current implementation sets the page LSN but has a TODO for true physiological redo (reapplying the actual payload). The comment at line 117-118 explains this limitation.

### Pass 3: Undo Pass
**Purpose**: Roll back all transactions that were active at crash time (present in ATT after analysis).

```zig
fn undo_pass(self: *RecoveryManager) !void
```

**Algorithm**:
1. Initialize `next_undo_lsns` with last_lsn of each transaction in ATT
2. While `next_undo_lsns` not empty:
   - Pick **maximum LSN** (process backwards chronologically)
   - Read that log record
   - If it's a data modification record:
     - Log undo action (TODO: true physiological undo with CLR generation)
   - If record has `prev_lsn != 0`:
     - Add `prev_lsn` to `next_undo_lsns` (continue walking undo chain)
   - Else: transaction fully undone

**Compensation Log Records (CLRs)**: ARIES requires writing CLRs during undo to log the undo actions themselves. Current implementation has this as a TODO (line 171-172).

## Mermaid: Recovery Flow

```mermaid
graph TD
    A[Startup] --> B[Analysis Pass]
    B --> C[Build ATT & DPT]
    C --> D[Redo Pass]
    D --> E[min_rec_lsn = min(DPT.recLSN)]
    E --> F[Scan WAL from min_rec_lsn]
    F --> G{page.lsn < record.lsn?}
    G -->|Yes| H[REDO: page.lsn = record.lsn]
    G -->|No| I[Skip]
    H --> J[Mark page dirty]
    I --> K[Next record]
    J --> K
    K --> F
    F -->|End| L[Undo Pass]
    L --> M[Initialize undo list from ATT]
    M --> N[Pick max LSN]
    N --> O[Read record]
    O --> P{Data modification?}
    P -->|Yes| Q[Log UNDO action]
    P -->|No| R[Continue]
    Q --> R
    R --> S{prev_lsn != 0?}
    S -->|Yes| T[Add prev_lsn to undo list]
    S -->|No| U[Txn fully undone]
    T --> N
    U --> N
    N -->|Empty| V[Recovery Complete]
```

## Trade-offs and Limitations

### Current Implementation Gaps
| Feature | Status | Location |
|---------|--------|----------|
| Physiological REDO | **Stub** - only updates LSN | `recovery_manager.zig:117` |
| Physiological UNDO | **Stub** - only logs action | `recovery_manager.zig:171` |
| Compensation Log Records (CLR) | **Missing** | `recovery_manager.zig:172` |
| Checkpoint support | **Partial** - reads but doesn't write | `recovery_manager.zig:63` |

### Design Decisions
1. **LSN = File Offset**: Simplifies positional I/O, enables replication streaming
2. **No Checkpoint Writing**: Checkpoints only read during analysis; not periodically written
3. **In-Memory ATT/DPT**: Rebuilt every recovery; no persistent checkpoint metadata
4. **Single-Threaded Recovery**: Sequential passes; could parallelize redo

## Related Documentation
- [Log Manager](./log_manager.md) — LSN allocation, flushing, replication triggers
- [Log Record Format](./log_record.md) — Header structure, record types, encoding
- [Transaction Context](./transaction.md) — TransactionContext, undo log, row locks
- [WAL Overview](../wal.md) — High-level architecture

## Cross-References in Code
- `src/storage/wal/recovery_manager.zig` — Main implementation
- `src/storage/wal/log_manager.zig` — LogManager used for reading WAL
- `src/storage/buffer_manager/buffer_manager.zig` — BufferManager for page access
- `src/storage/wal/log_record.zig` — LogRecordHeader, LogRecordType definitions