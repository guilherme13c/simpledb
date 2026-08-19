# Advanced SQL Features in SimpleDB

SimpleDB has been upgraded to support a powerful suite of advanced SQL querying features. These extensions operate within the Volcano-style query execution model and provide robust functionality for complex data analysis.

## Outer Joins
SimpleDB supports `LEFT OUTER JOIN`, `RIGHT OUTER JOIN`, and `FULL OUTER JOIN`.
*   **Execution:** Handled natively by the `NestedLoopJoinExecutor`.
*   **NULL padding:** When a tuple fails to match the join condition, it is emitted alongside a tuple entirely composed of `NULL` values corresponding to the missing relation.
*   **Syntax:**
    ```sql
    SELECT a.id, b.name 
    FROM a LEFT OUTER JOIN b ON a.id = b.id;
    ```

## Subqueries
Scalar subqueries are now a first-class feature in `WHERE` clauses.
*   **Execution:** Resolved during query planning. The optimizer intercepts `.compare_subquery` expressions, allocates an independent temporary query plan, executes the subquery to evaluate a scalar result, and replaces the subquery node with a static `.compare` node before generating the final execution plan.
*   **Syntax:**
    ```sql
    SELECT name, age FROM users WHERE age > (SELECT avg(age) FROM users);
    ```

## Common Table Expressions (CTEs)
CTEs (the `WITH` clause) allow you to name temporary result sets within a query.
*   **Execution:** CTEs are materialized entirely in memory as `InMemoryTable` instances. SimpleDB executes the CTE query block, pipes the output to an `InMemoryInsertExecutor`, and binds the temporary table to the `Catalog`. The main query accesses it via an `InMemoryScanExecutor`. Once the main query finishes, the temporary table is automatically dropped.
*   **Syntax:**
    ```sql
    WITH top_users AS (
        SELECT id FROM users WHERE score > 100
    )
    SELECT u.id, u.name 
    FROM users u INNER JOIN top_users t ON u.id = t.id;
    ```

## Window Functions
Analytic Window Functions are fully integrated!
*   **Execution:** Handled by the `WindowExecutor`. The executor buffers tuples, sorts them strictly by `PARTITION BY` and `ORDER BY` specifications, and iteratively applies analytic functions (`ROW_NUMBER()`, `RANK()`, `SUM()`, `COUNT()`). Finally, the standard `ProjectExecutor` overlays the results.
*   **Syntax:**
    ```sql
    SELECT id, category, score,
           ROW_NUMBER() OVER(PARTITION BY category ORDER BY score DESC)
    FROM scores;
    ```
