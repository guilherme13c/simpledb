# SimpleDB Project Brief

**SimpleDB** is a custom, lightweight, high-performance database engine built from scratch in Zig 0.16.0. 

The project was created to explore and implement fundamental, low-level database primitives. Rather than relying on external libraries or OS-level page caches, SimpleDB implements its own storage abstractions. It features a complete custom storage hierarchy ranging from disk-level positional I/O up to a multi-threaded TCP server capable of handling concurrent queries.

Currently, SimpleDB functions as an advanced Key-Value store with table management and range scan capabilities. 

### Core Objectives
- Deep dive into database storage architectures (Slotted Pages, B+Trees, Lazy Deletions).
- Implement performant, manual memory management (Buffer Pooling with Clock-Sweep eviction).
- Provide a robust concurrency model using Latch-Crabbing and Zig's non-blocking `std.Io` concurrency primitives.
- Expose a SQL-like TCP protocol for database interactions, parsed entirely via a custom Lexer and Parser.
- Ensure durability via a Logical Write-Ahead Log (WAL).
