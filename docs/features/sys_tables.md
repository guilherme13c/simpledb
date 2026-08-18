# Feature: System Tables (`sys_tables`)

## Location
`src/storage/catalog.zig`

## Overview
To prevent SimpleDB from suffering from "amnesia" on restarts, it utilizes a self-hosted metadata layer known as `sys_tables`.

Instead of relying on an external configuration file to remember the schema, SimpleDB eats its own dog food. It uses its very own Table and B+Tree mechanics to durably store the metadata mapping `table_name` -> `root_page_id`.

## Bootstrapping Sequence
1. **First Boot:** When a database file is initialized for the very first time (detected via a file size of 0), it automatically allocates Page 0 as the root of the `sys_tables` B+Tree.
2. **Normal Boots:** When the server restarts on an existing file, it checks the file size to restore the `next_page_counter`. It then initializes a B+Tree rooted at Page 0 and scans it from start to finish.
3. **Restoration:** For every tuple found during the scan, it extracts the `table_name` and the `root_page_id`, instantiates the corresponding `Table` objects in memory, and repopulates the Catalog's hash map.

## Operations
- **CREATE:** When `CREATE <table>` is called, a new entry is hashed and inserted into `sys_tables`.
- **DROP:** Because B+Trees lack a `delete` method in the current toy version, `DROP <table>` writes a **Tombstone** record into `sys_tables` (with `root_page_id` set to `std.math.maxInt(u32)`). On reboot, if the scanner encounters a Tombstone for a table, it safely removes it from the hash map, preventing dropped tables from resurrecting.
