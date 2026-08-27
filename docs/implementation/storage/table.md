# Table

## Overview

The `Table` is the core storage unit in the SimpleDB engine. It combines a BTree index for primary key management with slotted pages for efficient data storage and secondary indexes for flexible querying.

## Architecture

### Primary Storage: BTree

The table uses a BTree (`*BTree`) as its primary index, providing:
- Logical ordering of records by key
- Efficient range scans and ordered iteration
- Standard CRUD operations (insert, update, delete)

```zig
pub const Table = struct {
    btree: *BTree,
    buffer_manager: *BufferManager,
    current_heap_page_id: u32,
    next_alloc_page_id: *u32,
    schema: []const ColumnDef,
    allocator: std.mem.Allocator,
    indexes: std.StringHashMap(IndexDef),
    num_tuples: std.atomic.Value(u64),
};
```

### Secondary Indexes

Each table can maintain multiple indexes alongside its primary BTree. Two common index types are implemented:

#### Hash Index
- Provides O(1) exact-match lookups
- Stores RIDs in an `ArrayList` per bucket to handle collisions
- Used for fast key-based retrieval

#### BTree Index
- Maintains sorted order of indexed columns
- Enables range queries and ordered traversal
- Integrated into the table's `indexes` map

```zig
pub const IndexDef = struct {
    column_idx: usize,
    index_type: IndexType,
    btree: ?*HashIndex,
    hash_idx: ?*HashIndex,
};
```

### Page Management

Pages are managed through a `BufferManager` that handles:
- Frame allocation and unpinning
- Slotted views for efficient tuple extraction
- Memory pooling for frequently allocated objects

```zig
pub fn insert(self: *Table, txn_ctx: ?*TransactionContext, key: u64, data: []const u8) !u64 {
    // ... transaction handling ...
    const frame = try self.buffer_manager.fetch_frame(self.current_heap_page_id);
    // ... insert logic ...
}
```

## Operations

### Insert

Records are inserted into the BTree and associated secondary indexes:

```zig
pub fn insert(self: *Table, txn_ctx: ?*TransactionContext, key: u64, data: []const u8) !u64 {
    // Acquire exclusive row lock on the BTree root
    try self.btree.insert(txn_ctx, key, rid);
    
    // Update secondary indexes
    if (self.indexes.count() > 0 and self.schema.len > 0) {
        var it = self.indexes.iterator();
        while (it.next()) |kv| {
            const index_def = kv.value_ptr.*;
            if (self.extract_hash_key(data, index_def.column_idx)) |hash_key| {
                if (index_def.index_type == .btree) {
                    try index_def.btree.?.insert(txn_ctx, hash_key, rid);
                } else if (index_def.index_type == .hash) {
                    try index_def.hash_idx.?.insert(hash_key, rid);
                }
            }
        }
    }
    
    // Increment tuple count atomically
    self.num_tuples.fetchAdd(1, .monotonic);
    return rid;
}
```

### Search

Search operates at two levels:

1. **Primary key lookup** – Direct BTree search for O(log n) performance
2. **Secondary index lookup** – Hash or BTree index for O(1) or O(log n) depending on index type

```zig
pub fn search(self: *Table, allocator: std.mem.Allocator, txn_ctx: ?*TransactionContext, key: u64) !?[]u8 {
    // Fast path: direct BTree point lookup
    if (try self.btree.search(key)) |rid| {
        const heap_page_id: u32 = @intCast(rid >> 32);
        const slot_id: u16 = @intCast(rid & 0xFFFF);
        
        const frame = try self.buffer_manager.fetch_frame(heap_page_id);
        defer self.buffer_manager.unpin_frame(frame, false);
        
        const view = SlottedView.init(&frame.page, false);
        if (view.get_tuple(slot_id)) |full_data| {
            return full_data[8..]; // Return data after header
        }
    }
    
    // Fallback: scan if duplicates or multiple versions exist
    const rids = try self.btree.scan(allocator, key, key);
    defer allocator.free(rids);
    
    for (rids) |rid| {
        // Similar page lookup and tuple extraction as in search()
    }
    
    return null;
}
```

### Scan

Full table scans iterate through all pages and collect all tuples:

```zig
pub fn scan(self: *Table, allocator: std.mem.Allocator, txn_ctx: ?*TransactionContext, start_key: u64, end_key: u64) ![][]u8 {
    const rids = try self.btree.scan(allocator, start_key, end_key);
    defer allocator.free(rids);
    
    var results = std.ArrayList([]u8).empty();
    for (rids) |rid| {
        const heap_page_id: u32 = @intCast(rid >> 32);
        const slot_id: u16 = @intCast(rid & 0xFFFF);
        
        const frame = try self.buffer_manager.fetch_frame(heap_page_id);
        defer self.buffer_manager.unpin_frame(frame, false);
        
        const view = SlottedView.init(&frame.page, false);
        if (view.get_tuple(slot_id)) |full_data| {
            if (full_data.len >= 8) {
                const data = full_data[8..];
                results.append(data);
            }
        }
    }
    return results;
}
```

## Slotted Pages

Each page contains a fixed number of slots (typically 256) for tuples. The `SlottedView` wraps a page and provides efficient tuple extraction without full page deserialization:

```zig
pub const SlottedView = @import("page/slotted_view.zig").SlottedView;
```

Benefits of slotted pages:
- Minimal memory footprint per tuple
- Fast random access via slot indices
- Reduced garbage collection pressure

## Secondary Index Sync

When a table is created or modified, all secondary indexes are automatically synced with the primary BTree. This ensures consistency between the primary key and indexed columns.

```zig
// Called during table initialization
if (self.indexes.count() > 0) {
    var it = self.indexes.iterator();
    while (it.next()) |kv| {
        const index_def = kv.value_ptr.*;
        if (self.extract_hash_key(data, index_def.column_idx)) |hash_key| {
            if (index_def.index_type == .btree) {
                try index_def.btree.?.insert(txn_ctx, hash_key, rid);
            } else if (index_def.index_type == .hash) {
                try index_def.hash_idx.?.insert(hash_key, rid);
            }
        }
    }
}
```

## Summary

The `Table` combines a BTree for primary key management with slotted pages for compact storage and secondary indexes for flexible querying. This architecture balances:
- **Performance**: O(log n) primary lookups, O(1) hash index lookups
- **Flexibility**: Multiple index types per table
- **Efficiency**: Slotted pages reduce memory overhead
- **Consistency**: Automatic synchronization between indexes and primary key

This design enables SimpleDB to handle both high-throughput point queries and complex analytical workloads efficiently.
