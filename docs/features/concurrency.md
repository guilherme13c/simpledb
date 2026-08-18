# Feature: Latch Crabbing (Concurrency)

## Location
`src/storage/buffer_manager/buffer_manager.zig`
`src/storage/index/btree.zig`
`src/storage/index/btree_node.zig`

## Overview
To allow SimpleDB to scale across multiple client threads without lock contention corrupting the underlying `BTree` structures, we implemented full **Latch Crabbing** (also known as lock-coupling). 

Rather than using a single global lock to protect the entire tree for the duration of an operation, Latch Crabbing allows threads to traverse the tree by acquiring a lock on the child node *before* releasing the lock on the parent node. 

## Implementation Details

### Frame-Level RwLocks
Every `Frame` in the `BufferManager` is equipped with its own `std.Io.RwLock`. When a page is fetched via `lock_page(page_id, exclusive: bool)`, it intelligently acquires this latch. This ensures that no two threads can structurally mutate the same page concurrently, and that readers are safely isolated from writers.

### Read Crabbing
For read-only operations like `search` and `scan`:
1. The thread locks the root node in shared (read) mode.
2. It examines the node to find the correct child page ID.
3. It fetches and locks the child node in shared (read) mode.
4. **Only then** does it release the read lock on the parent node.
5. It repeats this process down to the leaf node, ensuring thread-safe traversal without blocking other readers.

### Write Crabbing
For mutating operations like `insert`:
1. The thread takes an optimistic approach, taking a shared lock on the `tree_latch`.
2. It evaluates the root node. If the root node is "safe" (i.e. it has enough free space that a split is impossible), it proceeds. If it is "unsafe", it escalates the `tree_latch` to an exclusive lock.
3. As it traverses down the tree during recursive inserts, it tracks an array of `locked_ancestors`.
4. At each step, it locks the child in exclusive (write) mode. 
5. It then queries the child node using `is_safe()`. If the child node has room to accept at least one more key without splitting, the algorithm knows that a structural split can never propagate back up past this node. 
6. Taking advantage of this, it immediately loops through the `locked_ancestors` array and unlocks/unpins all of them, holding only the lock for the current safe node.
7. If a split does occur at the leaf level, it is safely handled because the thread still holds the exclusive locks for every unsafe ancestor directly above it.

This robust mechanism ensures maximum throughput for concurrent operations while preserving strict B+Tree invariants.
