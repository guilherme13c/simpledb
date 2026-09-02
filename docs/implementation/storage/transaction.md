# Transaction context

Source: `src/storage/wal/transaction.zig`; lifecycle: `src/server/server.zig`
and `src/server/connection.zig`.

`TransactionContext` is an in-memory value with four fields: `txn_id`,
`prev_lsn` (initially zero), an optional `LockManager` pointer, and an optional
fixed-size `ActiveSnapshot`. It owns no memory, so `deinit` currently does
nothing. The server maintains the active-ID map and removes the entry in
`end_txn`; the connection handler calls `LockManager.unlock_all` on transaction
end.

The `prev_lsn` field is updated only by operations that append a record with a
context, allowing recovery's undo scaffold to follow a per-transaction chain.
It is not an undo log. Client rollback uses the separate logical `UndoOp`
stack in `src/server/undo.zig`, and its best-effort operations run without a
transaction context.

Visibility and row-lock semantics are documented in
[`../concurrency/mvcc.md`](../concurrency/mvcc.md).
