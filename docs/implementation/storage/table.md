# Table storage

Source: `src/storage/table.zig`.

A `Table` has a primary `BTree`, a current heap page, a shared page-ID counter,
a schema, an in-memory name-to-`IndexDef` map, and an atomic visible-count
approximation. The primary tree maps user-supplied `u64` keys to RIDs. An RID
packs `heap_page_id` in bits 32..63 and `slot_id` in the low 16 bits.

## Writes

`insert` prepends the MVCC header, tries the current slotted heap page, and
allocates a new heap page on `OutOfSpace`. It appends a logical WAL insert when
a log manager exists, obtains an exclusive row lock when there is a transaction
context, inserts `(key,RID)` into the primary tree, then adds the RID to every
secondary index. A stack buffer avoids heap allocation for logical payloads up
to 256 bytes. There is no uniqueness check and no rollback of already-written
heap/index state if a later step fails.

`delete` scans all primary-tree entries for the key, picks the first visible
tuple, and marks its `xmax`; it does not remove its primary or secondary index
entry. A non-transactional delete uses `u32.max`. `update` at the executor
level serializes a changed row and performs delete then insert.

## Reads and encoding

`search` first follows one primary-tree result, then scans equal-key entries if
that tuple is absent or invisible. `scan` scans the primary tree range, fetches
each RID, filters by MVCC visibility, and returns allocator-owned copies of user
tuple bytes.

`serialize_tuple` stores schema-ordered values without type tags: fixed values
are 8-byte little-endian (`int`, `float`, `timestamp`, `signed_int`), bool is
one byte, `varchar`/JSON are `u32` length plus bytes, UUID is 16 bytes. NULL is
rejected. `deserialize_tuple` trusts the buffer length for present fields and
substitutes type defaults only after the input ends; malformed partial values
are not defensively rejected.
