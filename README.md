# SimpleDB

**SimpleDB** is a custom, lightweight, high-performance database engine built from scratch in Zig 0.16.0.

It explores fundamental, low-level database primitives by implementing its own storage abstractions instead of relying on external libraries or OS-level page caches. 

## Documentation
The documentation has been split into several focused guides:

1. **[Project Brief](docs/brief.md)** - High-level overview and core objectives of the database project.
2. **[Architecture Overview](docs/architecture.md)** - A detailed breakdown of the internal systems (Storage, Buffer Pool, Indexing, Catalog, Query Parser, etc.).
3. **[Testing Suite](docs/testing.md)** - Overview of the `zig build test` coverage, what is tested, and what is currently untested (with justifications).
4. **[Profiling and Benchmarking](docs/profiling_and_benchmarking.md)** - Comprehensive guide to using the `zig build benchmark-report` feature and generating visual flamegraphs via `zig build flamegraphs`.

## Getting Started
Requirements:
- Linux
- Zig 0.16.0
- `perf` (linux-tools) for profiling

**Running Tests:**
```bash
zig build test
```

**Running Benchmark Report:**
```bash
zig build benchmark-report
```

**Generating Flamegraphs:**
```bash
zig build flamegraphs
```
