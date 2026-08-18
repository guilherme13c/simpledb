# Feature: Catalog & Tables

## Location
`src/storage/catalog.zig` and `src/storage/table.zig`

## Overview
SimpleDB supports multiple isolated data structures via a global `Catalog`.

## The Catalog
The Catalog is a thread-safe registry powered by a lightweight atomic SpinLock and a `std.StringHashMap`. It maps human-readable table names to physical `Table` structs in memory. 

Whenever a user executes a `CREATE` command, the Catalog allocates a new root page for the B+Tree, initializes a `Table`, and stores the mapping.

## The Table
The `Table` abstraction acts as the bridge between the logical index (B+Tree) and the physical data layout (Slotted Pages). When data is inserted, the `Table` places the raw bytes into a slotted page (often called a heap page), receives a Record ID (RID), and then inserts that `<Key, RID>` pair into the B+Tree index. When querying, it does the reverse: searches the B+Tree for the RID, then fetches the raw tuple from the heap page.
