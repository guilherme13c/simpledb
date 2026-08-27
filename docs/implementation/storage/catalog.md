# Catalog

## Overview

The `Catalog` serves as the central registry for all storage tables in the database. It manages table lifecycles, provides thread-safe name-to-table mappings, and coordinates secondary indexes.

## Key Components

### Thread-Safe Name-to-Table Mapping

The catalog uses a `StringHashMap` to map table names (strings) to `Table` instances. This provides O(1) average-time lookups by name.

```zig
pub const Catalog = struct {
    tables: std.StringHashMap(*Table),
    
    pub fn init(allocator: std.mem.Allocator, buffer_manager: *BufferManager, next_page_counter: *u32) !Catalog {
        var catalog = Catalog{
            .tables = std.StringHashMap(*Table).init(allocator),
            // ... other fields
        };
        return catalog;
    }
```

### Atomic Counter for Tuple Count

A `std.atomic.Value(u64)` tracks the total number of tuples across all tables, enabling efficient capacity planning and monitoring.

```zig
pub struct Table {
    num_tuples: std.atomic.Value(u64),
    // ... other fields
}
```

### Secondary Indexes

Each table can have multiple indexes defined in the `indexes` field (a `StringHashMap` of `IndexDef`). Common index types include:

- **Hash Index**: For exact-match lookups on a specific column
- **BTree Index**: For ordered traversal and range queries

```zig
pub const IndexDef = struct {
    column_idx: usize,
    index_type: @import("../query/ast.zig").IndexType,
    btree: ?*@import("index/hash_index.zig").HashIndex,
    hash_idx: ?*@import("index/hash_index.zig").HashIndex,
};
```

### Lifecycle Management

#### Initialization

During initialization, the catalog creates a system table (`sys_tables`) that holds metadata about all tables. This includes:
- Root page for the system table
- Primary BTree index for the system table
- Initial schema definition

```zig
pub fn init(allocator: ..., buffer_manager: ..., next_page_counter: *) !Catalog {
    // Create sys_tables root page
    const sys_root = next_page_counter.*;
    const sys_btree = try allocator.create(BTree);
    sys_btree.* = try BTree.init(...);
    
    // Create the system table
    const sys_table = try allocator.create(Table);
    sys_table.* = try Table.init(...);
    
    // Register the system table in the catalog
    const name_dup = try allocator.dupe(u8, "sys_tables");
    try catalog.tables.put(name_dup, sys_table);
}
```

#### Load System Tables

If the database is new, the catalog loads existing system tables from disk, parsing their schema definitions and populating the index structures.

#### Free Tables

When a table is deleted, the catalog frees its associated BTree, indexes, and schema, ensuring no memory leaks.

```zig
pub fn free_table(self: *Catalog, table: *Table) void {
    for (table.schema) |col| self.allocator.free(col.name);
    self.allocator.free(table.schema);
    self.allocator.destroy(table.btree);
    
    var idx_it = table.indexes.iterator();
    while (idx_it.next()) |idx_kv| {
        self.allocator.free(idx_kv.key_ptr.*);
        if (idx_kv.value_ptr.*.btree) |bt| self.allocator.destroy(bt);
        if (idx_kv.value_ptr.*.hash_idx) |hi| {
            hi.deinit();
            self.allocator.destroy(hi);
        }
    }
    table.indexes.deinit();
    self.allocator.destroy(table);
}
```

## Synchronization

The `Catalog` uses a `SpinLock` to protect concurrent access to the `tables` map and the `num_tuples` counter. This ensures that:
- Table registration and deletion are atomic
- The tuple count remains consistent during concurrent operations
- Index structures are not corrupted by simultaneous modifications

## Summary

The `Catalog` acts as the central authority for table management. It provides:
- **Fast name lookups** via `StringHashMap`
- **Atomic counters** for capacity tracking
- **Secondary index coordination** for flexible querying
- **Robust lifecycle management** with proper cleanup

This design allows the storage layer to dynamically track all tables and their associated indexes, enabling features like automatic schema evolution and safe table teardown.
