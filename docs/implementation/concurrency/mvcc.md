# MVCC and Concurrency Implementation

## Overview
SimpleDB uses Multi-Version Concurrency Control (MVCC) with latch-crabbing to provide lock-free reads while maintaining ACID properties.

## MVCC Design

### Tuple Header Format (8 bytes)
```zig
var mvcc_header: [8]u8 = undefined;
std.mem.writeInt(u32, mvcc_header[0..4][0..4], xmin, .little); // Transaction start
std.mem.writeInt(u32, mvcc_header[4..8][0..4], xmax, .little); // Transaction end (0 = active)
```

### Visibility Rules
```zig
const is_visible = if (txn_ctx) |ctx| ctx.is_visible(xmin, xmax) else (xmax == 0);
```

- **xmin**: Transaction ID that created the tuple
- **xmax**: Transaction ID that deleted the tuple (0 = not deleted)
- **Visible if**: xmin < current_txn AND (xmax == 0 OR xmax > current_txn)

### Undo Log
- Each transaction maintains an undo log
- Stores old values for UPDATE and DELETE operations
- Used by Recovery Manager for rollback

## Lock-Free Reads

### Read Operations
- Read transactions acquire no locks on tuples
- Visibility is determined by comparing xmin/xmax with transaction context
- Older versions of tuples are reconstructed using undo logs

### Write Operations
- Lock exclusive on affected rows
- Write new versions with updated xmin
- Mark old version with xmax

## Latch-Crabbing Protocol

### Lock Acquisition Order
1. Tree latch (shared or exclusive)
2. Root node latch
3. Child node latch
4. Release parent when safe

### Safety Conditions
- **Insert Safe**: Node has space (num_keys < capacity)
- **Delete Safe**: Node has enough keys (num_keys > capacity/2)

### Lock States
- **Shared**: Read-only access, multiple holders
- **Exclusive**: Write access, single holder

## Transaction Context

### Transaction Context
```zig
pub const TransactionContext = struct {
    txn_id: u32,
    prev_lsn: u32,
    undo_log: std.ArrayList(UndoRecord),
    row_locks: std.StringHashMap(RowLock),

    pub fn is_visible(self: *TransactionContext, xmin: u32, xmax: u32) bool {
        // Implementation checks visibility
    }

    pub fn lock_row_exclusive(self: *TransactionContext, root_page_id: u32, rid: u64) !void {
        // Lock a specific row
    }
};
```

## Recovery with MVCC

### Crash Recovery Process
1. Read last checkpoint from WAL
2. Replay committed transactions (REDO)
3. Rollback uncommitted transactions (UNDO)
4. Clean up leftover locks
5. Truncate WAL

## Trade-offs

### Advantages
- **No Read Locks**: Readers never block writers
- **Snapshot Isolation**: Point-in-time consistency
- **Fast Queries**: No lock acquisition overhead
- **Concurrent Writes**: Multiple transactions can modify different rows

### Disadvantages
- **Storage Overhead**: Multiple versions stored temporarily
- **Garbage Collection**: Old versions must be cleaned up
- **Memory Usage**: Undo logs consume memory
- **Complexity**: Visibility checks add overhead

### Alternatives
1. **Strict Two-Phase Locking (2PL)**: Simple but blocks readers
2. **Optimistic Concurrency Control (OCC)**: Validate at commit
3. **Read Committed**: Simpler isolation level
4. **Serializable**: More restrictive but stronger guarantees

## Performance
- **Read Latency**: O(1) for direct lookup, O(log n) for range scan
- **Write Latency**: O(log n) with latch acquisition
- **Memory**: Undo logs grow with transaction size
- **Concurrency**: Scales well with read-heavy workloads