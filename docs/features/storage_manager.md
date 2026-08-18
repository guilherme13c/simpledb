# Feature: Storage Manager

## Location
`src/storage/storage_manager/storage_manager.zig`

## Overview
The Storage Manager provides the foundational layer for all physical disk persistence in SimpleDB. 

## Positional I/O
Instead of relying on stateful `seek` operations that would require locks on the file descriptor across multiple threads, the Storage Manager uses positional reads and writes (`readPositional` and `writePositional`).

This allows the database to jump to any page offset instantly and read/write the 8KB `Page` blocks without interfering with concurrent I/O operations from other threads.
