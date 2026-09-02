# WAL record format

Source: `src/storage/wal/log_record.zig`.

`LogRecordType` is an `enum(u8)`: `begin`, `commit`, `abort`,
`insert_tuple`, `delete_tuple`, `update_tuple`, `update_page_meta`,
`checkpoint`, `logical_insert`, `logical_delete`, `prepare_txn`, and
`raft_config_change` have discriminants 0 through 11 respectively.

Each record is `@sizeOf(LogRecordHeader)` bytes of native `extern` header plus
`length - @sizeOf(LogRecordHeader)` opaque payload bytes. Do not hard-code a
32-byte header or field byte offsets: `term:u64` makes the layout alignment and
total size ABI-dependent. Writer and readers consistently use `@sizeOf`.

| Header field | Meaning |
| --- | --- |
| `lsn` | physical starting offset; recovery checks it against the scan offset |
| `prev_lsn`, `txn_id` | per-transaction chain metadata |
| `term` | copied from an optional Raft term atomic on append |
| `length` | complete record length, including header |
| `page_id`, `offset` | target metadata for physical records; logical table replication uses `page_id` as a table root id |
| `record_type` | selects payload interpretation outside this module |

Only logical replication payloads have a code-level convention: insert is
little-endian `key:u64` followed by serialized tuple bytes; delete is a
little-endian `key:u64`. The physical record types do not currently have an
implemented replay format.
