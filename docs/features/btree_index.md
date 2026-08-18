# Feature: B+Tree Index

## Location
`src/storage/index/btree.zig` and `src/storage/index/btree_node.zig`

## Overview
SimpleDB uses an unclustered B+Tree to provide fast `O(log N)` point lookups and efficient sequential range scans.

## Node Layout
Because SimpleDB operates on raw 8KB pages, the node metadata (e.g., node type, number of keys, and horizontal pointers) must be efficiently packed into the generic `PageHeader`. This is achieved using a 48-bit packed struct that maps directly into the header's `special` field via `@bitCast`.

- **Internal Nodes:** Contain `<Key, ChildPageID>` pairs. They act as signposts guiding the search query down to the leaves.
- **Leaf Nodes:** Contain the actual `<Key, RecordID>` mapping.

## Splitting
When a node exceeds the maximum capacity of its 8KB page, it splits perfectly in half. A new page is allocated, half the keys are shifted over, and the middle key is pushed up to the parent. This happens recursively if necessary, up to the root node.

## Range Scans
To support `SCAN` operations efficiently, leaf nodes maintain a `next_leaf` pointer (encoded as a 24-bit integer, supporting 16 million pages). This forms a singly-linked list at the base of the B+Tree, allowing the engine to effortlessly "walk" across leaves during range queries.
