# Write-Ahead Log (WAL) Implementation

## Overview
SimpleDB implements a physical logging WAL following ARIES principles. The WAL ensures durability and enables crash recovery.

## Log Manager

### LogManager Structure
```zig
pub const LogManager = struct {
    io: std.Io,
    wal_file: std.Io.File,
    mutex: std.Io.Mutex,
    global_lsn: std.atomic.Value(u32),
    flushed_lsn: std.atomic.Value(u32),
    current_offset: u32,
    cond: std.Io.Condition,
    current_term: ?*std.atomic.Value(u64),
};
```

### LSN as File Offset
- LSN = physical byte offset in WAL file
- Monotonically increasing
- Enables direct positional I/O for replication

## Log Record Structure

### LogRecordHeader
```zig
pub const LogRecordHeader = packed struct {
    term: u64,       // Leader term (for replication)
    lsn: u32,        // Log Sequence Number (file offset)
    prev_lsn: u32,   // Previous LSN for this transaction
    txn_id: u32,     // Transaction ID
    length: u32,     // Total record size including header
    page_id: u32,    // Affected page ID
    offset: u16,     // Offset within page
    record_type: LogRecordType,
    _padding: u8 = 0,
};
```

### LogRecordType Enum
```zig
pub const LogRecordType = enum(u8) {
    begin = 0,
    commit = 1,
    rollback = 2,
    insert_tuple = 3,
    delete_tuple = 4,
    update_page_meta = 5,
    logical_insert = 6,    // For replication
    logical_delete = 7,    // For replication
    checkpoint = 8,
    undo = 9,
};
```

## Key Operations

### append_record()
1. Acquire mutex
2. Calculate total size = header + payload
3. Write header at current_offset
4. Write payload after header
5. Update current_offset
6. Update global_lsn atomically
7. Broadcast condition variable for replication
8. Release mutex
9. Return LSN

### flush(lsn)
1. Check if already flushed
2. Acquire mutex
3. Double-check
4. Call wal_file.sync() for fsync
5. Update flushed_lsn
6. Release mutex

## Transaction Context

### TransactionContext
```zig
pub const TransactionContext = struct {
    txn_id: u32,
    prev_lsn: u32,
    undo_log: std.ArrayList(UndoRecord),
    row_locks: std.StringHashMap(RowLock),
};
```

### Undo Records
- Track changes for rollback
- Store old tuple data for UPDATE/DELETE
- Used by recovery manager for crash recovery

## Replication Support

### Logical Records
- logical_insert: Contains (key, data) for INSERT
- logical_delete: Contains key for DELETE
- Applied by replica without re-executing SQL

### Replication Flow
1. Leader writes physical WAL
2. Parallel logical records generated
3. Streamed to replicas over TCP
4. Replicas apply to local catalog

## Recovery Process

### RecoveryManager
1. Read WAL from last checkpoint
2. REDO: Replay all committed transactions
3. UNDO: Rollback uncommitted transactions
4. Truncate WAL at recovered state

## Trade-offs

### Advantages
- **Durability**: WAL before data pages
- **Replication**: Logical records for streaming
- **Crash Recovery**: ARIES-style recovery

### Disadvantages
- **I/O Overhead**: Double write (WAL + data)
- **Complexity**: Recovery logic is complex
- **Sequential Bottleneck**: Single WAL file

### Alternatives
1. **Group Commit**: Batch multiple transactions
2. **Log-Structured**: LSM-tree style
3. **No Logging**: In-memory only (not durable)

## Mermaid: WAL Flow
```mermaid
graph TD
    A[Transaction] --> B[append_record]
    B --> C[Write Header]
    C --> D[Write Payload]
    D --> E[Update global_lsn]
    E --> F[Broadcast Condition]
    F --> G[Return LSN]
    H[Flusher Thread] --> I[flush(lsn)]
    I --> J[fsync WAL File]
    J --> K[Update flushed_lsn]
    L[Replication] --> M[Read Logical Records]
    M --> N[Stream to Replicas]
```
