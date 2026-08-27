# Query Operations

Core operators executed by the query engine (`src/query/executor/`). User-facing behavior with syntax examples. Internal mechanics link to `implementation/`.

## Scan Operators

### SeqScan (`seq_scan.zig`)
Reads every row from a table sequentially. Default when no usable index exists or for small tables.
```sql
SELECT * FROM users;
```
Use for unfiltered full-table reads; prefer IndexScan when filtering on indexed columns.

### IndexScan (`index_scan.zig`)
Uses B-Tree or hash index to retrieve only matching rows. Triggered by `WHERE` on indexed columns.
```sql
SELECT * FROM users WHERE id = 42;
SELECT * FROM users WHERE name = 'Ada';
```
When CBO estimates few matches, picks IndexScan over SeqScan.

## Filtering & Projection

### Filter (`filter.zig`)
Applies `WHERE` conditions (compare, column_compare, `AND` expressions; subquery `compare_subquery`).
```sql
SELECT * FROM orders WHERE total > 100 AND status = 'shipped';
SELECT * FROM employees WHERE dept_id IN (SELECT id FROM departments WHERE region = 'EU');
```

### Project (`project.zig`)
Selects/renames columns (`SELECT col1, col2`). `*` expands to full row.
```sql
SELECT id, name FROM users;
```

## Joins

### NestedLoop (`nested_loop_join.zig`)
Nested loop over left and right; best for small relations or when index on right available.
```sql
SELECT * FROM a JOIN b ON a.id = b.a_id;
SELECT * FROM a LEFT JOIN b ON a.id = b.a_id;
SELECT * FROM a RIGHT JOIN b ON a.id = b.a_id;
SELECT * FROM a FULL JOIN b ON a.id = b.a_id;
```

### SortMerge (`sort_merge_join.zig`)
Sorts both sides on join key then merges. Good for sorted/ordered inputs.
```sql
SELECT * FROM orders JOIN customers ON orders.customer_id = customers.id ORDER BY orders.id;
```

### Hash (`hash_join.zig`)
Builds hash table on smaller input, probes with larger. Best for medium/large unindexed joins.
```sql
SELECT * FROM users JOIN orders ON users.id = orders.user_id;
```

CBO picks join order and type by cardinality estimates.

## Aggregation (`aggregate.zig`)
`GROUP BY` on single column; aggregates `count`, `sum`, `min`, `max`, `avg`.
```sql
SELECT dept_id, COUNT(*), AVG(salary) FROM employees GROUP BY dept_id;
```

## Ordering & Limits

### OrderBy (`order_by.zig`)
`ORDER BY col [DESC]`.
```sql
SELECT * FROM products ORDER BY price DESC;
```

### Limit (`limit.zig`)
`LIMIT n [OFFSET m]`.
```sql
SELECT * FROM logs ORDER BY created_at DESC LIMIT 50 OFFSET 10;
```

## Window Functions (`window.zig`)
`row_number`, `rank`, `sum`, `count`; partition + order.
```sql
SELECT id, score, RANK() OVER (PARTITION BY dept ORDER BY score DESC) FROM results;
```

## Subqueries (`compare_subquery` in `ast.zig`)
Correlated/subquery in `WHERE` conditions (e.g., `IN`, comparisons).
```sql
SELECT * FROM products WHERE category_id IN (SELECT id FROM categories WHERE active = true);
```

## CTEs (`with`, `Cte`)
Named temporary result: `WITH cte_name AS (SELECT ...) SELECT ...`
```sql
WITH top_sales AS (SELECT user_id, SUM(amount) AS total FROM orders GROUP BY user_id)
SELECT * FROM top_sales WHERE total > 1000;
```

## CBO Operator Selection
The planner compares cardinality estimates: IndexScan when selective filter/index present; SeqScan for full scans; NestedLoop for small inputs, Hash for larger, SortMerge when sorted. See `implementation/query_plan.md`.

## Links
- Implementation: `implementation/query_executor.md`, `implementation/query_plan.md`
- Storage/index: `features/indexing.md`, `features/storage.md`
- SQL reference: `features/sql_reference.md`
