# Lock manager

Source: `src/storage/concurrency/lock_manager.zig`.

The lock table maps a 64-bit resource key to a FIFO array of
`{txn_id, mode, granted}` requests. A second map records each transaction's
resource keys for `unlock_all`; a third marks transactions chosen for killing.
The single mutex protects all three maps and all queues.

A shared request is grantable when no other transaction holds exclusive; an
exclusive request is grantable only when no other transaction has a granted
request. Re-requesting a granted lock succeeds. Requesting exclusive after a
shared request changes that same entry into an upgrade. The policy does not
honour FIFO ordering for new shared requests, so an exclusive waiter can starve.

Waiters poll every 10 ms, up to 101 attempts (about one second), rather than
waiting on the queue condition. A timeout or killed mark removes the request
and returns `error.DeadlockDetected`. `kill_transaction` sets the mark and
broadcasts queue conditions, but the acquisition loops do not wait on those
conditions. `unlock` and `unlock_all` remove requests and broadcast. No lock
escalation, intent mode, reentrancy count, or deadlock prevention is present.
