# Request execution

Source: `src/server/execution.zig`.

`execute_statement` dispatches parsed AST nodes to catalog/table operations or
builds a stack-allocated executor tree. It supports DDL, DML, transactions,
`EXPLAIN`, and `WITH` temporary tables. INSERT serializes values, treats column
zero as an unsigned primary key, writes through `Table.insert`, and records a
`delete_key` undo entry. DELETE scans matching rows and records enough bytes to
reinsert them; UPDATE is delete-plus-insert and is not added to that undo stack.

For a `WHERE` expression that is an extractable primary/secondary index
condition, the planner chooses an index scan whenever the hard-coded cost 4 is
not greater than tuple count; otherwise it uses a sequential scan plus filter.
For an inner equijoin it compares simple cardinality formulas and generally
chooses hash join; nonmatching forms use nested loops. It has no statistics,
selectivity, plan cache, join reordering, predicate pushdown, or disk-spilling.

Executor tuples and strings are allocator-owned. The dispatcher opens the final
operator, pulls until `null`, formats pipe-separated values, and closes it.
