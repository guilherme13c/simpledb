# SimpleDB Architecture

SimpleDB is composed of a layered architecture that distinctly separates storage, memory, indexing, and networking concerns. The stack is designed bottom-up:

### 1. Storage Manager (`storage_manager.zig`)
The lowest tier. It utilizes **io_uring** for asynchronous, high-throughput, non-blocking I/O operations directly with the Linux kernel. It bypasses conventional blocking I/O, allowing concurrent SQE submissions and a highly efficient polling-based event loop (`std.Thread.yield()`) for CQE completions to maximize queue depth and throughput.

### 2. Buffer Manager (`buffer_manager.zig`)
The memory tier. This component manages a fixed-size pool of `Frame` objects. It utilizes a **Clock-Sweep** (Second-Chance) algorithm to intelligently evict cold pages. It is highly concurrent, spawning dedicated background `flusher_thread` and `prefetch_thread` workers to asynchronously flush dirty pages and prefetch contiguous sequences via `io_uring`, maximizing SSD throughput. It handles page pinning and unpinning using global locking and per-frame `std.Io.RwLock` instances for latching.

### 3. Page Layouts (`page.zig` & `slotted_view.zig`)
The format tier. Every page is strictly 8KB with a 16-byte packed header. 
- **Slotted Pages:** Used for storing variable-length tuples (data records).
- **Index Pages:** Managed by the B+Tree nodes, leveraging the `special` header field to store custom metadata (like node types, key counts, and neighbor pointers).

### 4. Indexing (`btree.zig` & `btree_node.zig`)
The lookup tier. SimpleDB uses an unclustered B+Tree architecture.
- **Internal Nodes:** Route keys to children.
- **Leaf Nodes:** Store actual `<Key, Record_ID>` pairs. Leaf nodes maintain a horizontal linked-list pointer to support fast range scans.
- **Concurrency:** Uses **Latch-Crabbing** (Read and Write crabbing with `is_safe` lock release) to provide extremely high concurrent throughput.
- **Deletions:** Uses **Active Node Merging** (`merge_leaf`, `merge_internal`, `delete_recursive`) with latch-crabbing to continuously consolidate underutilized B+Tree nodes.

### 5. Table & Catalog (`table.zig` & `catalog.zig`)
The logical tier. A `Table` couples a primary B+Tree with the Slotted Pages required to store raw data. It supports **Secondary Indexes** which are dynamically created and automatically synchronized upon `INSERT` and `DELETE` mutations. The `Catalog` acts as a central, thread-safe registry mapping string names (e.g., `"users"`) to their underlying `Table` objects.
- **Concurrency Control (MVCC):** Utilizes **Multi-Version Concurrency Control (MVCC)** to allow lock-free reads while transactions write concurrently. It maintains an **Undo Log** for each transaction to construct older versions of tuples for snapshot isolation, guaranteeing serializability and point-in-time consistency without blocking readers.

### 6. Query Parsing & Execution (`lexer.zig`, `parser.zig`, `ast.zig`, `executor.zig`)
The syntax and compute tier. SimpleDB implements a custom SQL subset. Incoming queries are tokenized by the `Lexer`, parsed into an Abstract Syntax Tree (AST) by the `Parser`, and structured into logical execution nodes. These nodes are then executed using a **Volcano-style Iterator Model** (`executor.zig`) supporting sequential/index scans, projections, filtering, hash aggregations (`GROUP BY`), and sort-merge/nested-loop joins.

### 7. Interface Tier (`server.zig` & `cli.zig`)
The interface tier provides two distinct interaction models:
- **TCP Server:** A multi-threaded TCP server built on `std.Io` event loops. It accepts incoming connections, feeds raw queries into the Query Parser, and executes the resulting AST against the Catalog. 
- **CLI / REPL:** A native interactive shell directly piped via `--cli`, sharing the server's transaction and WAL context for testing and local scripting.

Both interfaces implement **Physical Logging** via ARIES, immediately saving transaction mutations (Analysis, Redo, Undo) into a Write-Ahead Log (`simpledb.wal`) before acknowledging commits, ensuring ACID properties.
