# Query executor

Sources: `src/query/executor.zig` and `src/query/executor/`.

Execution follows a pull interface: every `Executor` union alternative exposes
`open`, `next -> ?[]Value`, and, where needed, `close`. Returned tuples are
allocator-owned. `dupe_value` copies `varchar` and JSON bytes; `free_tuple`
must release them before the tuple array. `format_tuple` writes values as
pipe-separated text.

| Operator | Current algorithm |
| --- | --- |
| Seq / index scan | Materialize primary-tree RIDs in `open`, fetch/decode one visible tuple at a time. Sequential scan keeps its current heap frame pinned across same-page RIDs. |
| Filter / project / limit | Pull child rows; filter frees rejected rows, project copies selected columns, limit discards offset rows then stops at count. |
| Nested loop | Materializes the right input; supports its implemented join-type padding. |
| Hash join | Materializes a hash table from the right input keyed by `ValueContext`; used only for inner equijoins selected by the dispatcher. |
| Sort-merge join | Materializes and sorts both inputs in memory; supports inner equal-key output. |
| Aggregate / window / order | Blocking in-memory operators. Aggregate groups in a hash map; window sorts its materialized rows once per requested window function; order materializes and `std.sort`s. No disk spill. |
| Insert / delete / update | Mutation wrappers. Update is table delete followed by insert. |

`compare_values` requires matching value tags. Ordering is defined for numbers,
timestamps, UUID bytes, and strings; JSON and bool only accept equality or
inequality; NULL comparisons return false. `evaluate_expression` currently
implements literal comparison and `AND` for single-table rows; column-vs-column
and subquery comparisons are handled only in join-specific evaluation or are
unsupported.

`try_extract_index_condition` recognizes primary-key equality/range and
secondary-index equality forms. Planning and operator construction are in
`src/server/execution.zig`, not in the executor modules.
