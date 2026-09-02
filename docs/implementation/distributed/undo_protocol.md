# Logical undo stack

Source: `src/server/undo.zig`; entries are recorded in
`src/server/execution.zig` and owned per connection.

The connection keeps `ArrayList(UndoOp)`, where `delete_key { table_name, key
}` compensates an insert by calling `Table.delete(null, key)`, and `insert_key
{ table_name, key, value }` compensates a delete by calling
`Table.insert(null, key, value)`. `execute_undo_stack` walks entries in reverse
and logs errors rather than returning them. `clear_undo_stack` frees the copied
names and insert payloads then retains list capacity.

This is best-effort logical compensation, not WAL undo: it has no transaction
context, does not restore an exact deleted duplicate/version, and can leave
partial effects on error. It runs on explicit rollback and when a connection
ends with an open transaction. Lock-manager deadlock killing merely causes a
waiting acquisition to return `DeadlockDetected`; it does not itself execute a
connection's undo stack.
