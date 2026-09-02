# In-memory table

Source: `src/storage/in_memory_table.zig`.

This is the backing store for temporary tables/CTEs, not a test-only B-tree
variant. `InMemoryTable` duplicates every schema name and every input `Value`
(including owned varchar/JSON bytes) into `ArrayListUnmanaged([]Value)`.
`InMemoryScanExecutor` returns a fresh duplicate of each stored tuple, while
`InMemoryInsertExecutor` consumes rows from a child executor and appends them.

It has no index, MVCC header, lock, persistence, update/delete API, or internal
synchronization. `Catalog.create_temp_table` and `drop_temp_table` own its
lifecycle.
