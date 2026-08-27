# Hash Index

## Overview

The `HashIndex` provides a high-performance hash-based index for storing and retrieving RIDs (record identifiers) by numeric key. It uses an `AutoHashMap` backed by an `ArrayList` of 64-bit integers, offering O(1) average-time lookups.

## Key Features

- **Collision Handling**: When multiple records share the same hash bucket, RIDs are stored in an `ArrayList` within the hash bucket, allowing multiple records to map to the same hash value.
- **Thread Safety**: The index is designed for concurrent access. While the `HashIndex` itself is not explicitly synchronized in this module, it relies on the caller to manage thread safety when inserting/deleting RIDs.
- **Comparison with BTree**: Unlike the BTree index (which maintains sorted order and range queries), the hash index prioritizes constant-time lookups. The BTree is used for ordered traversal and range scans, while the hash index excels at exact-key retrieval.

## Implementation Details

### Structure

```zig
pub const HashIndex = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u64, std.ArrayList(u64)),
};
```

The index consists of:
- An `allocator` for memory management
- A `map` that maps a 64-bit key to an `ArrayList` of RIDs (handling collisions)

### Operations

#### Insert
```zig
pub fn insert(self: *HashIndex, key: u64, rid: u64) !void {
    const res = try self.map.getOrPut(key);
    if (!res.found_existing) {
        res.value_ptr.* = std.ArrayList(u64).empty;
    }
    try res.value_ptr.*.append(self.allocator, rid);
}
```
- Uses `getOrPut` to retrieve or create an empty `ArrayList` for the key.
- Appends the RID to the list, handling collisions naturally.

#### Delete
```zig
pub fn delete(self: *HashIndex, key: u64, rid: u64) void {
    if (self.map.getPtr(key)) |list| {
        for (list.items, 0..) |item, i| {
            if (item == rid) {
                _ = list.swapRemove(i);
                break;
            }
        }
        if (list.items.len == 0) {
            list.deinit(self.allocator);
            _ = self.map.remove(key);
        }
    }
}
```
- Removes the RID from the appropriate list if found.
- Cleans up the empty list and removes the key from the map.

#### Search
```zig
pub fn search(self: *HashIndex, allocator: std.mem.Allocator, key: u64) ![]u64 {
    if (self.map.get(key)) |list| {
        const result = try allocator.alloc(u64, list.items.len);
        @memcpy(result, list.items);
        return result;
    }
    return try allocator.alloc(u64, 0);
}
```
- Returns a pointer to the array of RIDs for the given key, or an empty array if not found.

## Trade-offs vs BTree

| Aspect | HashIndex | BTree |
|--------|-----------|-------|
| Lookup Speed | O(1) average | O(log n) |
| Memory Overhead | Lower (simple list per bucket) | Higher (node pointers, metadata) |
| Range Queries | Not supported | Supported (range scans) |
| Ordering | No inherent order | Sorted by key |
| Concurrency | Basic (caller-managed) | Built-in (row locks) |

**When to use**: The hash index is ideal for exact-match lookups where speed is critical and ordering doesn't matter. The BTree complement provides ordered traversal and range queries.

## Usage Example

```zig
const HashIndex = @import("storage/index/hash_index.zig");
const hashIdx = HashIndex{ .allocator = myAllocator };

// Insert records
hashIdx.insert(hashIdx, 12345, 0xABCDEF); // key=12345, rid=0xABCDEF

// Retrieve RIDs
if (ridArray := hashIdx.search(hashIdx, 12345)) {
    const rid = ridArray[0];
    // Use rid to look up the record
}

// Delete
hashIdx.delete(hashIdx, 12345, 0xABCDEF);
```

## Summary

The `HashIndex` offers a lightweight, fast alternative to the BTree for scenarios requiring constant-time key lookups. Its simple structure makes it easy to integrate, while the BTree handles the more complex ordering and range-query needs.
