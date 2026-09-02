# Write-ahead log

Sources: `src/storage/wal/{log_record,log_manager,recovery_manager,transaction}.zig`.

The WAL is an append-only byte file. An LSN is the starting byte offset of a
record; `global_lsn` and `current_offset` point just after the last appended
record. `append_record` holds one mutex while it writes the native `extern`
header and then the opaque payload with positional I/O. It broadcasts `cond`
after the append. `flush(lsn)` synchronizes the complete WAL file only when
`flushed_lsn < lsn`, then publishes the current end offset as `flushed_lsn`.

The page writer observes WAL ordering: eviction, the background flusher,
checkpoint, and shutdown call `LogManager.flush(page.header.lsn)` before
writing a dirty page when a log manager is installed.

`LogRecordHeader` is a native-layout `extern struct`, so its exact byte layout
is ABI-dependent even though the fields are fixed in source. The following
fields are written: `lsn:u32`, `prev_lsn:u32`, `txn_id:u32`, `term:u64`,
`length:u32` (header plus payload), `page_id:u32`, `offset:u16`,
`record_type:u8`, and one padding byte. Payloads have no shared schema.

The current users emit logical insert/delete payloads (primary key followed by
tuple bytes), page-metadata records, transaction markers, checkpoints, and
Raft config records. Normal transaction commit records are appended by the
connection code but are not forced before the response. See `recovery.md` for
the recovery limitations.
