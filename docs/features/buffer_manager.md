# Feature: Buffer Manager

## Location
`src/storage/buffer_manager/buffer_manager.zig`

## Overview
The Buffer Manager is the beating heart of SimpleDB's performance. Disk I/O is notoriously slow, so SimpleDB caches actively used pages in a fixed-size, in-memory pool (currently sized at 4096 frames). 

## Mechanisms
- **Pinning:** When a system component requests a page (e.g., to traverse a B+Tree node), the Buffer Manager "pins" the page in memory. A pinned page cannot be evicted.
- **Eviction:** When a new page is requested and the pool is full, the manager scans the frames for an unpinned page (pin count == 0) and evicts it. 
- **Dirty Flushes:** If a page was modified, it is marked as `dirty`. Before eviction, the Buffer Manager ensures dirty pages are safely written back to disk via the `StorageManager`.
- **Thread Safety:** The entire frame array and page-mapping hash map are protected by an `std.Io.Mutex`, allowing concurrent database queries to request and mutate pages safely.
