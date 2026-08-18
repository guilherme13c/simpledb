# Feature: Write-Ahead Log (WAL)

## Location
`src/server/server.zig`

## Overview
While the `sys_tables` feature durably persists the metadata, any unevicted dirty pages residing in the Buffer Manager's memory pool are lost if the server crashes unexpectedly. To address this, SimpleDB utilizes a Write-Ahead Log (WAL).

## Implementation
Given the educational and experimental nature of SimpleDB, the WAL implements a **Logical Logging** strategy.

Instead of physiologically logging byte diffs for every single memory page change (which requires a very complex recovery algorithm like ARIES), the Server intercepts all mutating commands (`CREATE`, `DROP`, `PUT`) arriving at the TCP boundary.

1. **Logging**: Before a command modifies the in-memory tree, the server locks a global `std.Io.Mutex` and appends the raw text command string to a `simpledb.wal` file on disk.
2. **Replay on Boot**: When the server initializes, before it opens the TCP listener to the world, it sequentially reads the entire `simpledb.wal` file line by line. It executes every command back into the engine, flawlessly rebuilding all un-evicted memory state and restoring total consistency.

Because the `sys_tables` layer handles schema persistence at the disk-page level, the logical WAL works symbiotically with it to ensure that even unevicted data inserts are never lost.
