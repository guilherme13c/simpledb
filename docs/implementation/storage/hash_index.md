# Hash index

Source: `src/storage/index/hash_index.zig`.

`HashIndex` is an in-memory `AutoHashMap(u64, ArrayList(u64))`: one derived
column key maps to zero or more RIDs. `insert` appends, `delete` swap-removes
the first matching RID and destroys an empty bucket, and `search` returns an
allocator-owned copy of a bucket (including a zero-length allocation for a
miss). There is no deduplication, range operation, lock, persistence, or
rebuild from catalog metadata.

`Table.extract_hash_key` derives the map key as follows: unsigned integer
unchanged; `varchar` hashed with seed-zero Wyhash; boolean `0`/`1`; float and
signed integer bit-cast to `u64`; all other value kinds map to zero. Hash
indexes are maintained on table insert only. `Table.delete` does not remove
secondary-index entries, so an index scan must still apply tuple visibility and
can observe stale RIDs.
