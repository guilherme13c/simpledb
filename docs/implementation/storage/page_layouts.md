# Page Layouts Implementation

## Overview
SimpleDB uses fixed-size 8KB pages with two main layouts: slotted pages for data storage and index pages for B+Tree structures.

## Page Structure

### PageHeader (16 bytes packed)
```zig
pub const PageHeader = packed struct(u128) {
    lsn: u32,        // Log Sequence Number
    checksum: u32,    // Page checksum
    lower: u13,       // Offset to free space start
    upper: u13,       // Offset to free space end
    special: u38,     // Node metadata for index pages
};
```

### Page Layout
- Header: 16 bytes at the start
- Content: 8176 bytes of usable space
- Alignment: 4096-byte aligned for optimal I/O

## Slotted Pages (Data Storage)

### Concept
Slotted pages manage variable-length tuples using a slot array that grows from the bottom and data that grows from the top. This allows efficient space utilization and in-place updates.

### Slot Structure
```zig
pub const Slot = packed struct {
    offset: u13,   // Byte offset to tuple data
    length: u13,   // Tuple length in bytes
};
```

### Memory Layout
+-------------------+
|PageHeader (16B)|
+-------------------+
| Slot 0           |  <- lower (grows down)
|Slot 1|
|...|
|Slot N|
+-------------------+
|FREE|
|SPACE|
+-------------------+
| Tuple Data       |  <- upper (grows up)
|Tuple Data|
+-------------------+

### SlottedView Operations

#### insert_tuple(header, data)
- Calculates space needed: header_len + data_len + slot_size
- Checks if space is available
- Allocates data space from top (decrements upper)
- Allocates slot from bottom (increments lower)
- Stores offset and length in slot
- Returns slot_id

#### get_tuple(slot_id)
- Calculates slot offset: slot_id * 4
- Validates slot within lower bound
- Reads offset and length from slot
- Returns slice of content array

#### update_xmax(slot_id, xmax)
- Used for MVCC to mark tuple as deleted
- Updates xmax field in MVCC header (bytes 4-8)

## Index Pages (B+Tree Nodes)

### Node Type
```zig
pub const NodeType = enum(u1) {
    internal = 0,
    leaf = 1,
};
```

### BTreeMetadata (stored in special field)
```zig
pub const BTreeMetadata = packed struct(u38) {
    node_type: NodeType,  // 1 bit
    num_keys: u13,       // Number of keys in node
    next_leaf: u24 = 0,  // Next leaf page (for range scans)
};
```

### Leaf Node Layout
- Stores KeyValue pairs: key (u64) + value (RID: u64)
- Binary search via leaf_search()
- Linked list via next_leaf for sequential range scans
- Capacity: 8176 / 16 = 511 keys

### Internal Node Layout
- First 4 bytes: leftmost_child page ID
- Remaining: InternalEntry array (key + right_child + padding)
- Capacity: (8176 - 8) / 16 = 510 entries

## Capacity Calculations

### Leaf Node
- KeyValue size: 16 bytes
- leaf_capacity = 8176 / 16 = 511 keys maximum

### Internal Node
- InternalEntry size: 16 bytes
- 8 bytes reserved for leftmost child pointer
- internal_capacity = (8176 - 8) / 16 = 510 entries maximum

## Trade-offs

### Advantages
- Fixed Size: Simplifies I/O and addressing
- No Fragmentation: Slotted pages handle variable-length data
- In-place Updates: Slot mechanism allows modifications

### Disadvantages
- Page Splits: Large tuples cause expensive page splits
- Internal Fragmentation: Wasted space from fixed allocations
- Metadata Overhead: Header and slot array consume space

### Alternatives
1. Variable Page Sizes: More flexible but complex
2. Row-Store vs Column-Store: Different analytics trade-offs
3. LSM-Trees: Write-optimized but require compaction

## Mermaid Diagram
graph TD
    A[PageHeader] --> B[Slotted Page]
    A --> C[Index Page]
    B --> D[Slot Array - grows down]
    B --> E[Free Space]
    B --> F[Tuple Data - grows up]
    C --> G[BTreeMetadata]
    C --> H[Leaf: KeyValue pairs]
    C --> I[Internal: Leftmost + Entries]
    H --> J[Linked List via next_leaf]