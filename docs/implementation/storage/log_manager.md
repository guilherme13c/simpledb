# Log manager

Source: `src/storage/wal/log_manager.zig`.

`LogManager` serializes `append_record` and slow-path `flush` with one mutex.
On startup it initializes all offsets from the existing WAL file size; offsets
and LSNs are `u32`, limiting a WAL to 4 GiB. Append writes header then payload
positionally at `current_offset`, advances `current_offset`, stores the new end
in `global_lsn` with release ordering, and broadcasts a condition variable.

`flush(requested_lsn)` fast-paths when `flushed_lsn >= requested_lsn`; otherwise
it synchronizes the entire file and publishes `current_offset`, not the exact
requested LSN. The mutex prevents append interleaving but cannot make two
separate positional writes crash-atomic. `current_term`, when configured by the
server, is sampled during append and placed in the record header.
