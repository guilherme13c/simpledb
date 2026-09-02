# Recovery manager

Source: `src/storage/wal/recovery_manager.zig`.

`RecoveryManager.recover` executes three sequential passes over the WAL range
`[0, LogManager.current_offset)`. It is ARIES-shaped scaffolding, not a full
ARIES implementation.

| Pass | Implemented work | Deliberately missing work |
| --- | --- | --- |
| Analysis | Reads headers until a short read or an LSN that does not equal the byte offset. Builds ATT (`txn_id -> last_lsn`) and DPT (`page_id -> first physical-change LSN`). Removes ATT entries on `commit` and `abort`. | Checkpoint start, payload validation, transaction-status persistence |
| Redo | Starts at the smallest DPT LSN; for physical `insert_tuple`, `delete_tuple`, and `update_page_meta`, fetches the page and advances `page.header.lsn` if stale. | Applying the logged bytes |
| Undo | Takes each active transaction's last LSN, repeatedly selects the largest LSN, and follows `prev_lsn`. | Reversing bytes, CLRs, abort records, durable completion |

Logical records are not replayed by this manager. A short/corrupt record stops
the current scan rather than repairing or truncating the WAL. Consequently it
must not be presented as a crash-recovery durability guarantee.
