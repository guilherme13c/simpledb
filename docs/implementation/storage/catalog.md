# Catalog

Source: `src/storage/catalog.zig`.

The catalog owns two name maps under a spin lock: persistent `tables` and
in-memory temporary tables. `get_table`/`get_temp_table` take the lock only
while looking up a pointer; callers then use that pointer without lifetime
protection, so concurrent DDL and query execution are not fully safe.

On an empty database, page 0 is formatted as a leaf B+tree and becomes the
root of `sys_tables`. Every persistent `CREATE TABLE` allocates and formats a
new primary-tree root, creates a `Table`, and inserts metadata into `sys_tables`
under `Wyhash(name)`. The metadata payload is:

```
root_page_id:u32 little-endian | column_count:u8 |
  repeat(column_type:u8 | name_length:u8 | name bytes) | table name bytes
```

Opening a non-empty file assumes page 0 is `sys_tables`, scans it, and rebuilds
each table. A root ID of `u32.max` is a drop tombstone. `ALTER TABLE` updates
only the in-memory schema then records a replacement catalog row; prior rows
remain in the system table. Dropping a table removes the map entry and writes a
tombstone but leaks its pages. The catalog does not persist secondary-index
definitions, heap-page position, or tuple counts.

`create_index` builds a B+tree or in-memory hash index and backfills it from
the primary tree. A B+tree secondary index gets a new persisted root page, but
the missing catalog definition means it is unreachable after restart.
