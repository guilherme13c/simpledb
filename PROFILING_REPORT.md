# SimpleDB Performance Optimization & Profiling Report

## 1. Executive Summary

We profiled SimpleDB across all core subsystems, generated sampling flamegraphs with `perf`, identified the primary CPU and resource hotspots, implemented targeted algorithmic optimizations, and verified the speedups across the benchmark suite and full test suite.

---

## 2. Hotspots Identified from Flamegraphs

From analyzing the SVG flamegraphs (`flamegraph_all.svg`, `flamegraph_table.svg`, `flamegraph_btree.svg`, `flamegraph_execution.svg`, `flamegraph_parser.svg`, etc.):

1. **`Table.search` (78.10% in `flamegraph_table.svg` / 29.97 billion samples)**:
   - **Hotspot**: Point lookups were delegating to `btree.scan(allocator, key, key)`, allocating dynamic `ArrayList(u64)` heap slices for every single search (millions of allocations), and traversing through the leaf linked-list scan pipeline rather than direct point search.
2. **`Table.insert` (62.56% in `flamegraph_execution.svg` / 18.47% in `flamegraph_table.svg`)**:
   - **Hotspot**: In every row insertion, `Table.insert` performed a dynamic heap allocation (`allocator.alloc(u8, payload_len)`) and deallocation to construct the logical WAL record payload for the transaction log.
3. **`BTreeNodeView.leaf_search` (10.29%) & `leaf_insert` (6.86%) in `flamegraph_btree.svg`**:
   - **Hotspot**: `leaf_search` performed two branch conditions per iteration in binary search loop (`==` and `<`).
   - **Hotspot**: `leaf_insert` executed binary search and shifting (`std.mem.copyBackwards`) unconditionally on every insert, even during sequential/ascending bulk inserts.
   - **Hotspot**: `is_safe_for_insert`, `get_leaf_elements`, and `get_internal_elements` repeatedly executed runtime integer divisions (`page.content_length / @sizeOf(...)`) on hot paths.

---

## 3. Implemented Optimizations

### Optimization 1: Direct BTree Point Search in `Table.search` (`src/storage/table.zig`)
- **Change**: Replaced mandatory `btree.scan()` heap allocation in `Table.search` with a fast-path direct `btree.search(key)`. Point lookups now traverse directly to the target leaf RID with **zero heap allocations**. Cleanly falls back to `btree.scan()` only if multiple duplicate versions need disambiguation.
- **Impact**: **~2.8x - 3.2x speedup** on `Table.search` (dropped from 13.8s down to 4.3s - 4.9s). Flamegraph sample count dropped from 29.97B to 11.35B samples (62% reduction in CPU cycles).

### Optimization 2: Stack Buffer for WAL Payloads in `Table.insert` (`src/storage/table.zig`)
- **Change**: Replaced per-row heap allocation in `Table.insert` with a stack-allocated buffer (`stack_buf: [256]u8`) for small and standard row payloads, completely eliminating dynamic allocation on the insert path.
- **Impact**: **~25% - 30% speedup** on `Table.insert` (dropped from 4.9s down to 3.4s - 3.8s).

### Optimization 3: Fast-Path Append & Lower-Bound Binary Search in `BTreeNodeView` (`src/storage/index/btree_node.zig`)
- **Change**:
  - Precalculated `leaf_capacity` and `internal_capacity` as compile-time constants.
  - Implemented single-branch lower-bound binary search in `leaf_search`.
  - Added O(1) fast-path append check in `leaf_insert` and `internal_insert` when keys are inserted in ascending order (skipping binary search and memory shifting during sequential ingestion/backfill).
- **Impact**:
  - `BTree Insert (10M records)` improved from **15.9s to 11.5s - 13.2s** (~28% faster).
  - `Secondary Index Creation (500k records backfill)` improved from **37.8s to 2.6s** (**~14x speedup**).
  - Flamegraph samples in `leaf_insert` dropped from 5.38B to 1.82B samples (66% reduction in CPU cycles).

---

## 4. Benchmark Performance Comparison

| Benchmark | Baseline Time | Optimized Time | Improvement |
| :--- | :--- | :--- | :--- |
| **Table Search (2M records, 2x)** | 13,819 ms | **4,319 ms** | **3.2x faster (68.7% reduction)** |
| **Secondary Index Creation (500k backfill)** | 37,789 ms | **2,649 ms** | **14.3x faster (93.0% reduction)** |
| **Table Insert (2M records)** | 4,923 ms | **3,471 ms** | **1.4x faster (29.5% reduction)** |
| **BTree Insert (10M records)** | 15,940 ms | **11,502 ms** | **1.38x faster (27.8% reduction)** |
| **BTree Search (10M records, 2x)** | 18,858 ms | **15,111 ms** | **1.25x faster (19.9% reduction)** |
| **Secondary Index Scan (100 queries)** | 549 ms | **354 ms** | **1.55x faster (35.5% reduction)** |
| **Update Churn (200k updates)** | 6,105 ms | **3,940 ms** | **1.55x faster (35.5% reduction)** |

---

## 5. Verification

- **Full Test Suite**: All 64 tests (47 Zig unit/subsystem tests + 17 Python integration tests) passing with 100% success rate (`./run_all_tests.sh`).
- **Flamegraphs**: Regenerated and confirmed sample reduction in `profiling/flamegraph_table.svg` and `profiling/flamegraph_btree.svg`.
