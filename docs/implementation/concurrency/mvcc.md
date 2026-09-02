# MVCC visibility

Source: `src/storage/wal/transaction.zig`; tuple integration is in
`src/storage/table.zig` and `src/storage/page/slotted_view.zig`.

## Stored version data

Every tuple written by `Table.insert` starts with an eight-byte, little-endian
header, followed by the serialized user columns:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `xmin`: creating transaction id (`0` for a non-transactional/system write) |
| 4 | 4 | `xmax`: deleting transaction id (`0` while live, `u32.max` after a non-transactional delete) |
| 8 | variable | table tuple bytes |

`SlottedView.update_xmax` changes bytes 4..8 in place. An update is therefore
implemented as `delete(old primary key)` followed by `insert(new tuple)`; it is
not a linked version chain.

## Snapshot and visibility

`Server.start_txn` copies the IDs that are active at begin time into the fixed
`ActiveSnapshot.items[256]` array, assigns the next atomic ID, then registers
the transaction. Starting a transaction fails after 256 simultaneously
captured active IDs.

`TransactionContext.is_visible(xmin, xmax)` returns true only when:

1. `xmin` is zero, the current transaction, or less than the current ID and
   absent from the start snapshot; and
2. `xmax` is zero, greater than the current ID, or present in the start
   snapshot. `u32.max` is always invisible.

Reads without a context simply accept `xmax == 0`. `SeqScanExecutor`,
`Table.search`, and `Table.scan` all decode this prefix before returning data.

## Locks and limits

Shared row locks are deliberately a no-op. Exclusive row locks hash
`(root_page_id, rid)` with Wyhash and use the lock manager when a context has
one. This is snapshot filtering plus write locking, not a complete MVCC
implementation: there is no commit table, rollback visibility state, garbage
collection, version chain, or serializable validation.
