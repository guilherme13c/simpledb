# B+tree

Sources: `src/storage/index/{btree,btree_node}.zig`.

The tree maps unsigned 64-bit keys to unsigned 64-bit values (table values are
RIDs). Nodes occupy one page and use sorted fixed-width arrays. Leaf nodes
store `{ key:u64, value:u64 }`; internal nodes store a leftmost `u32` child
followed by `{ key:u64, right_child:u32, padding:u32 }`. The page-header
`special` field is bit-cast to `BTreeMetadata { node_type:1, num_keys:13,
next_leaf:24 }`. Details and capacities are in `page_layouts.md`.

`search` descends with shared frame latches and binary-searches the leaf.
`scan(start,end)` descends to the leaf for `start`, walks `next_leaf`, and
returns every value whose key is in the inclusive range. Duplicate keys are
kept as separate leaf entries; point lookup returns one matching value.

Insertion uses a tree read/write latch plus exclusive page latches. It holds
ancestors until it reaches an insert-safe node, then releases them (latch
crabbing). A full leaf is split half-and-half, linked to its former successor,
and its new first key is propagated. A full internal node promotes its middle
key. A root split allocates and installs a new internal root. The temporary
ancestor array has capacity 16 levels.

Deletion removes one matching key. If a non-root leaf becomes empty its parent
removes the child pointer; the same propagation can remove an empty internal
node, and an empty internal root is replaced by its leftmost child. It does
not redistribute, merge non-empty siblings, reclaim pages, or repair separator
keys after arbitrary deletions. Treat this as a learning implementation, not
a space-balanced production B+tree.
