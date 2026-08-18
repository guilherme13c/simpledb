# Non-Negotiables & Engineering Principles

When working on SimpleDB, the following strict guidelines must be adhered to at all times:

1. **Zig 0.16.0 Standard Library Only:**
   - No external C libraries.
   - The project strictly uses Zig 0.16.0. API usage must align with the features and syntax of this version.

2. **I/O and Concurrency Primitives:**
   - Due to the networking model, all I/O and threading must go through `std.Io`.
   - **DO NOT** use `std.Thread.Mutex`. Use `std.Io.Mutex` or `std.Io.RwLock`. 
   - **DO NOT** use `std.net` sockets directly. Use `std.Io.Threaded.openSocketPosix` or similar `std.Io` networking functions.
   - For custom synchronization not supported by `std.Io`, use manual atomic primitives (e.g., `std.atomic.Value` SpinLocks).

3. **Memory Management:**
   - Avoid dynamic allocation per-query where possible.
   - Rely heavily on the `BufferManager` for caching and state management.
   - All structures mapping to disk (e.g., `PageHeader`, `BTreeMetadata`) must use `packed struct` to guarantee exact bit-widths and byte layouts without padding.

4. **Data Integrity:**
   - Pages must strictly adhere to the 8KB size limit.
   - Modifying a page must ALWAYS be paired with setting the `is_dirty` flag when unpinning to ensure durability.
