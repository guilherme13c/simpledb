# Feature: Deletions

## Location
`src/storage/index/btree.zig`
`src/storage/index/btree_node.zig`
`src/storage/table.zig`
`src/server/server.zig`

## Overview
SimpleDB now supports deleting tuples from its underlying index structures. The `DELETE` command removes a given key-value pair from the table.

## Implementation Details
We adopted a **Lazy Deletion** mechanism to simplify the underlying `B+Tree` logic and avoid complex node-merging strategies that can negatively impact concurrent performance:

1. **Leaf Pruning**: When `btree.delete(key)` is invoked, it traverses down the tree using **Optimistic Write-Crabbing**. As it walks down the tree, it locks pages in write mode but immediately unlocks the parent (because no internal structure modification occurs).
2. **Key Extraction**: Once at the leaf node, the key is linearly searched. If found, the array of tuples is shifted left to overwrite the target tuple.
3. **Capacity Maintenance**: The leaf `num_keys` is decremented. If a node becomes under-full or even completely empty, the system makes no attempt to rebalance the B+Tree or merge it with siblings. It remains in the leaf chain, preserving concurrent stability and structural integrity without costly global rebalancing overhead.
4. **Network Integration**: The simple `DELETE <table_name> <key>` TCP command invokes this functionality and accurately records the event to the WAL for immediate persistence.
