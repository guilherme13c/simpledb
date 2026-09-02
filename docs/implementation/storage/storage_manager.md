# Storage manager

Source: `src/storage/storage_manager/storage_manager.zig`.

`StorageManager` opens the database read/write with `O_DIRECT` first and falls
back without direct I/O only when the platform rejects that flag. It creates a
Linux `io_uring` with 256 entries. Pages use positional offsets
`page_id * 8192`.

Single-page and batch reads/writes submit `prep_read`/`prep_write` SQEs under a
ring mutex. Batches are capped at 128 requests. Completion polling elects one
thread via `leader_lock` to call `IORING_ENTER_GETEVENTS` and dispatch up to 64
CQEs to their stack-allocated `IoContext`; followers yield until their `done`
flag is published. A short successful read is zero-filled. A non-negative CQE
result is accepted without checking that a write completed all 8192 bytes.

`start` currently has no work, and `deinit` destroys the ring and closes the
file. This module is Linux-specific because it imports `std.os.linux.IoUring`.
