# Page layouts

Sources: `src/storage/page/{page,slotted_view}.zig` and
`src/storage/index/btree_node.zig`.

`Page` is 8192 bytes: a 128-bit packed `PageHeader` aligned to 4096 bytes plus
8176 content bytes. Header fields are `lsn:u32`, `checksum:u32`, `lower:u13`,
`upper:u13`, and `special:u38`. The checksum field is declared but never
calculated or verified.

For a heap page, `SlottedView.init(..., true)` sets `lower=0` and `upper=8176`.
Each packed slot is four bytes (`offset:u13`, `length:u13`). Slots grow upward
from content offset zero and tuple bytes grow downward from `upper`; `insert`
fails if the regions would meet. A slot identifier is `slot_offset / 4` and is
part of the RID `page_id << 32 | slot_id`. Slots are never reclaimed or
compacted.

For a B+tree page, `special` holds `BTreeMetadata`: one node-type bit, 13-bit
key count, and 24-bit next-leaf ID. Leaf capacity is `8176 / 16 = 511`
`{u64 key, u64 value}` entries. Internal nodes reserve the first eight content
bytes (only the first four contain the leftmost child) and hold at most
`(8176 - 8) / 16 = 510` `{u64 key, u32 right_child, u32 padding}` entries.
