# SQL Reference

Complete reference for the SQL subset supported by SimpleDB's custom lexer/parser (`src/query/lexer.zig`, `src/query/parser.zig`).

---

## Supported Data Types

Based on the `DataType` enum (`parser.md`):

| Type | Description | Example | Notes |
|------|-------------|---------|-------|
| `int` | Signed integer | `INT`, `SIGNED_INT` (alias) | Base integer type |
| `varchar` | Variable-length string | `VARCHAR(100)` | Only `varchar` (not `char`) |
| `bool` | Boolean | `BOOL` | `BOOLEAN` is NOT a keyword |
| `float` | Floating-point number | `FLOAT` | `DOUBLE PRECISION` NOT supported |
| `timestamp` | Date/time value | `TIMESTAMP` | `DATE` NOT supported |
| `json` | JSON document | `JSON` | Stored as text |
| `uuid` | Universally unique identifier | `UUID` | 16 bytes |

**NOT supported:** `char`, `decimal`, `numeric`, `binary`, `date`, `smallint`, `bigint`, `boolean` (use `bool`), `signed_int` is just an alias for `int`.

---

## Basic Statements

### SELECT

Retrieve data from one or more tables.

```sql
SELECT column1, column2, COUNT(*) 
FROM table_name 
WHERE condition 
GROUP BY column1, column2 
ORDER BY column1 DESC;
```

**Supported clauses:** `SELECT`, `FROM`, `WHERE`, `GROUP BY`, `ORDER BY`, `LIMIT` (no `HAVING`, `OFFSET` is NOT in lexer tokens — only `LIMIT`).

### INSERT

Add rows to a table.

```sql
INSERT INTO table_name (col1, col2, col3)
VALUES ('value1', 'value2', 'value3');
```

Multiple rows via repeated values (supported by parser):

```sql
INSERT INTO table_name (col1, col2)
VALUES ('a', 1), ('b', 2);
```

Also supports: `INSERT INTO table SELECT ...` (subquery insert).

### UPDATE

Modify existing rows.

```sql
UPDATE table_name
SET col1 = new_value1, col2 = new_value2
WHERE condition;
```

**Note:** `WHERE` is required for safe updates; omitting it updates all rows.

### DELETE

Remove rows from a table.

```sql
DELETE FROM table_name
WHERE condition;
```

**Note:** Deleting all rows requires `WHERE 1=1` or similar; there is no `TRUNCATE`.

### CREATE TABLE (DDL)

```sql
CREATE TABLE table_name (
    column_name data_type,
    ...
);
```

**Supported features:**
- `CREATE INDEX idx ON table (column) USING btree|hash`
- No `PRIMARY KEY`, `NOT NULL`, `REFERENCES`, `UNIQUE`, `DEFAULT`, `CHECK` constraints (not in lexer/parser)
- No `IF NOT EXISTS` syntax

Example:

```sql
CREATE TABLE users (id INT, name VARCHAR(100), active BOOL);
CREATE INDEX idx_users_name ON users(name) USING btree;
```

### DROP

```sql
DROP TABLE table_name;
DROP INDEX idx_name ON table_name;
```

**NOT supported:** `IF EXISTS` (not in tokens). No `DROP INDEX` without `ON`.

### ALTER TABLE (DDL)

Based on `KeywordAlter`, `KeywordAdd`, `KeywordColumn`, `KeywordDrop`, and the `AlterTableStmt` structure (`parser.md`):

```sql
ALTER TABLE table_name ADD column_name data_type;
ALTER TABLE table_name ADD COLUMN column_name data_type;  -- ADD + COLUMN keywords
ALTER TABLE table_name RENAME COLUMN old_name TO new_name;  -- if parser supports
```

**Supported operations (from changelog + parser):**
- `ALTER TABLE ... ADD COLUMN ...` (add column)
- `ALTER TABLE ... RENAME COLUMN ...` (rename column — from CHANGELOG)
- `ALTER TABLE ... DROP COLUMN ...` (drop column — from parser tokens: `KeywordDrop` + `KeywordColumn`)

**NOT supported:** `MODIFY` (not a keyword), `RENAME TO` (table rename not explicitly supported by tokens — only column rename is mentioned in changelog), `IF EXISTS`, `ALTER INDEX`, `ALTER CONSTRAINT`.

---

## Expressions and Operators

### Operators (from TokenType enum in parser)

**Comparison:** `=`, `!=` (`<>` is NOT supported — parser uses `Neq` for `!=` only), `<`, `>`, `<=`, `>=`

**Logical:** `AND`, `OR`, `NOT`

**Arithmetic:** `+`, `-`, `*`, `/`, `%` (modulo)

**String:** No `||` (concatenation) operator in tokens — string concatenation is NOT explicitly supported.

**In-operator:** `IN` (supported by parser tokens: `KeywordIn`)

### Aggregate Functions

From changelog and `executor/aggregate.zig` usage:

```sql
SELECT COUNT(*), SUM(salary), MIN(salary), MAX(salary), AVG(salary)
FROM table_name
GROUP BY department_id;
```

### Window Functions

From changelog and `executor/window.zig`:

```sql
SELECT 
    name,
    salary,
    ROW_NUMBER() OVER (ORDER BY salary DESC) AS rank,
    SUM(salary) OVER (PARTITION BY dept_id) AS dept_total
FROM users;
```

**Supported functions:** `row_number`, `rank`, `sum`, `count`, `min`, `max`, `avg` (as window functions with `PARTITION BY` / `ORDER BY`).

---

## Control Structures

### CTE (Common Table Expression) — `WITH`

```sql
WITH dept_totals AS (
    SELECT department_id, SUM(salary) AS total
    FROM employees
    GROUP BY department_id
)
SELECT * FROM dept_totals WHERE total > 100000;
```

### Subqueries

Subqueries are supported as expressions (compare_subquery in AST):

```sql
SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE amount > 500);
SELECT * FROM (SELECT * FROM table WHERE condition) AS sub;
```

### Prepared Statements — `PREPARE`

```sql
PREPARE stmt FROM 'SELECT * FROM users WHERE id = ?';
```

Note: The parser supports `KeywordPrepare` and `prepare` statement type, but full parameter binding may be limited.

---

## EXPLAIN

```sql
EXPLAIN SELECT * FROM users WHERE id = 1;
```

Returns query execution plan: operators selected (SeqScan/IndexScan), join strategy (NestedLoop/Hash/SortMerge), filter predicates, projection columns, and estimated cost.

---

## Query Operators (Implementation Reference)

For details on how each operator works internally (Volcano iterator, frame caching, CBO selection), see:
- [Implementation: Query Operators](implementation/query/executor.md)
- [Features: Query Operations](query_operations.md)
- [Features: Indexing](indexing.md)
