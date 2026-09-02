# Connection lifecycle

Source: `src/server/connection.zig`.

Each accepted TCP stream has a detached handler with a 128 KiB input buffer.
It splits at either CR or LF, accepts SQL text plus `ROUTER`, `RAFT_*`, and
`START_REPLICATION` control lines, and writes results through a buffered stream
writer. The handler retains `in_transaction`, an optional `TransactionContext`,
and a logical undo stack.

`BEGIN` acquires the server's shared transaction/DDL lock, calls `start_txn`,
and appends a `begin` WAL record when possible. `COMMIT` appends `commit`,
clears the undo stack, releases all locks, ends the transaction, and releases
the shared lock. `ROLLBACK` executes the logical undo stack, appends `abort`,
then follows the same cleanup. An EOF or handler return while a transaction is
open runs the rollback path via `defer`.

DDL takes the exclusive server lock. Reads and DML take a shared one unless a
transaction already holds it. Replicas allow only select and transaction-control
commands. The wire protocol has no authentication, statement timeout, or
per-connection resource limit beyond the fixed input buffer.
