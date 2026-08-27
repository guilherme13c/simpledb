# In-Memory Table

## Overview

The `InMemoryTable` is a test-only implementation of a table that resides entirely in memory. It demonstrates the core concepts of the storage layer without persistence concerns, making it ideal for benchmarking and testing.

## Structure

```zig
pub const InMemoryTable = struct {
    allocator: std.mem.Allocator,
    schema: []const ast.ColumnDef,
    tuples: std.ArrayListUnmanaged([]ast.Value), // Unmanaged tuples for speed
    
    pub fn init(allocator: std.mem.Allocator, schema: []const ast.ColumnDef) !InMemoryTable {
        const schema_dupe = try allocator.alloc(ast.ColumnDef, schema.len);
        for (schema, 0..) |col, i| {
            schema_dupe[i] = .{
                .name = try allocator.dupe(u8, col.name),
                .data_type = col.data_type,
            };
        }
        return .{
            .allocator = allocator,
            .schema = schema_dupe,
            .tuples = std.ArrayListUnmanaged([]ast.Value).empty(),
        };
    }
    
    pub fn deinit(self: *InMemoryTable) void {
        for (self.schema) |col| {
            self.allocator.free(col.name);
        }
        self.allocator.free(self.schema);
        for (self.tuples.items) |tuple| {
            free_tuple(self.allocator, tuple);
        }
        self.tuples.deinit(self.allocator);
    }
    
    pub fn insert_tuple(self: *InMemoryTable, tuple: []const ast.Value) !void {
        var duped = try self.allocator.alloc(ast.Value, tuple.len);
        for (tuple, 0..) |v, i| {
            duped[i] = try dupe_value(self.allocator, v);
        }
        try self.tuples.append(self.allocator, duped);
    }
};
```

## Key Characteristics

### Memory Efficiency
- Tuples are stored in `std.ArrayListUnmanaged` to avoid heap allocations for the tuple data itself
- Only the outer `InMemoryTable` struct is allocated on the heap
- Values are duplicated from the schema definition rather than copied

### Lifecycle

The table is designed for temporary use:
- `init()` creates an empty table with a schema
- `insert_tuple()` adds records to the in-memory list
- `deinit()` cleans up all allocated resources

Because there is no persistence layer, the table is lost when the program exits. This makes it suitable for:
- Performance benchmarks
- Unit testing storage operations
- Development and prototyping

### Data Flow

1. **Insertion**: A tuple is converted to a `Value` and allocated on the heap via `dupe_value()`
2. **Storage**: The tuple is appended to the `tuples` list
3. **Retrieval**: Tuples can be accessed via the `tuples` list (though no public API exposes this in the current implementation)

## Testing Value

The in-memory table is particularly useful for:
- Measuring insertion and search latency without I/O overhead
- Validating index synchronization logic
- Benchmarking the hash index and BTree performance
- Testing edge cases (large tuples, duplicate keys, etc.)

## Limitations

- No persistence: data is lost on program termination
- No concurrent access: not thread-safe without additional synchronization
- Limited functionality: lacks advanced features like transactions, snapshots, or foreign key enforcement

## Summary

The `InMemoryTable` provides a lightweight, fast implementation of the table concept for testing and benchmarking purposes. It demonstrates the core storage mechanics (BTree indexing, secondary indexes, tuple management) without the complexity of disk I/O or persistence concerns.
