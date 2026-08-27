# Indexing

SimpleDB supports primary (B+Tree) and secondary indexes (B+Tree / Hash) with automatic sync and optimizer selection.

## Index Types

### Primary B+Tree Index

**What is it:** Every table in SimpleDB has a primary B+Tree index automatically created on the first column defined in `CREATE TABLE`. This index organizes the table's data in sorted order and serves as the main access path.

**Characteristics:**
- **Automatic creation:** Built when the table is created (no explicit `PRIMARY KEY` syntax)
- **First column:** The first column in `CREATE TABLE` becomes the primary index key
- **Range capability:** Supports equality (`=`), less-than (`<`), greater-than (`>`), and BETWEEN predicates
- **Ordering:** Keys stored in sorted order, enables range scans and ORDER BY without additional sort
- **Space efficiency:** High storage density with leaf node linked-list for sequential traversal

```sql
-- First column (id) becomes primary B+Tree index
CREATE TABLE users (id INT, name VARCHAR(100), email VARCHAR(100));

-- Range scan on primary index
SELECT * FROM users WHERE id BETWEEN 10 AND 20;
```

**NOT supported:** `PRIMARY KEY` keyword, `UNIQUE` constraints, `NOT NULL` constraints.

### Secondary B+Tree Index

**What is it:** An unclustered B+Tree index on additional columns for faster lookup, providing both equality and range query capabilities.

**Characteristics:**
- **Explicit creation:** Created via `CREATE INDEX`
- **Ordering:** Sorted keys like primary B+Tree
- **Range queries:** Supports all comparison operators and BETWEEN
- **Maintenance overhead:** Updated on INSERT/UPDATE/DELETE operations
- **Coverage:** Stores record IDs (RIDs) pointing to actual data rows

**When to use:**
- Columns frequently used in SELECT WHERE conditions with equality or range
- Support for ORDER BY on indexed columns without sorting
- Historical data access patterns

**Syntax:**
```sql
CREATE INDEX idx_users_name ON users(name);
CREATE INDEX idx_users_email ON users(email);
```

### Hash Index

**What is it:** A hash-based index providing constant-time equality lookups, optimized for point queries.

**Characteristics:**
- **Fast lookup:** O(1) average time for exact matches
- **Equality only:** Supports only equality predicates (`=`)
- **No ordering:** Does NOT support range queries, ORDER BY, or sorting
- **Memory usage:** Smaller memory footprint compared to B+Tree for equality lookups
- **Collision handling:** Built-in handling for hash collisions

**When to use:**
- Columns used exclusively with equality conditions
- Lookups by exact values (e.g., user authentication, ID lookups)
- Performance-critical exact-match scenarios

**Syntax:**
```sql
CREATE INDEX idx_users_email_hash ON users(email) USING hash;
```

## How Indexes Work

### Storage Architecture

**Primary B+Tree Index:**
- **File structure:** Stored as dedicated B+Tree pages (`src/storage/index/btree.zig`)
- **Page format:** Internal nodes route keys to child pages; leaf nodes store key-value pairs
- **Concurrency control:** `std.Io.RwLock` per node with latch-crabbing for high concurrency
- **Page linking:** Leaf nodes maintain horizontal linked-list for efficient range scans

**Secondary Indexes:**
- **B+Tree:** Unclustered; data rows remain in original table order
- **Hash index:** In-memory hash map (`AutoHashMap<u64, []u64>`) for fast equality lookup
- **Multi-table support:** Catalog maps table names to their respective indexes

### Automatic Synchronization

All indexes maintain consistency automatically:

```sql
-- Create table (primary index on first column created automatically)
CREATE TABLE orders (id INT, user_id INT, amount FLOAT, order_date TIMESTAMP);

-- Create secondary indexes
CREATE INDEX idx_orders_user ON orders(user_id);
CREATE INDEX idx_orders_date ON orders(order_date) USING hash;
```

**Updates:**
- **INSERT:** New indexes receive the new key+RID pair
- **UPDATE:** Indexes on modified columns are updated (old entry removed, new entry added)
- **DELETE:** Entries removed from all indexes on the deleted row
- **All indexes:** Updated synchronously with main table operations

### Query Optimizer Index Selection

The optimizer (`executor/index_scan.zig`) chooses access methods based on:

**Equality Predicates:**
```sql
WHERE email = 'user@example.com'
-- Optimizer selects: Hash index if available, otherwise B+Tree
```

**Range Predicates:**
```sql
WHERE id BETWEEN 1000 AND 2000
-- Optimizer selects: B+Tree index (range scan capability)
```

**Mixed Conditions:**
```sql
WHERE email = 'user@example.com' AND id > 1000
-- Optimizer may combine index lookups or use primary index access
```

**Non-Indexed Columns:**
```sql
WHERE name = 'John Doe'
-- Optimizer selects: Sequential scan (full table scan)
```

## Usage Examples

### Creating and Using Different Index Types

```sql
-- Create table with multiple columns (first column = primary index)
CREATE TABLE employees (
    employee_id INT,
    department_id INT,
    salary FLOAT,
    hire_date TIMESTAMP,
    full_name VARCHAR(255)
);

-- Secondary B+Tree for range queries
CREATE INDEX idx_employees_department ON employees(department_id);

-- Secondary B+Tree for exact matches and ordering
CREATE INDEX idx_employees_full_name ON employees(full_name);

-- Hash index for exact-match lookups
CREATE INDEX idx_employees_salary ON employees(salary) USING hash;

-- Range query using B+Tree index (primary or secondary)
SELECT * FROM employees
WHERE hire_date BETWEEN '2020-01-01' AND '2023-12-31'
ORDER BY hire_date;

-- Exact match using hash index
SELECT * FROM employees
WHERE salary = 75000.00;

-- Exact match using B+Tree index
SELECT * FROM employees
WHERE department_id = 5;

-- Multiple index usage (if optimizer chooses)
SELECT * FROM employees
WHERE department_id = 5 AND salary > 50000
ORDER BY full_name;
```

### Index Management

```sql
-- Drop indexes when not needed
DROP INDEX idx_employees_department;
DROP INDEX idx_employees_full_name;
DROP INDEX idx_employees_salary;

-- Recreate with different types
DROP INDEX idx_employees_full_name;
CREATE INDEX idx_employees_full_name ON employees(full_name) USING btree;
-- Later: DROP and recreate as hash
DROP INDEX idx_employees_full_name;
CREATE INDEX idx_employees_full_name ON employees(full_name) USING hash;
```

### Query Optimization with Indexes

**Example 1: Small table, many lookups**
```sql
-- Table size: 10,000 rows
-- Query: Find user by email (1 lookup per query)
CREATE INDEX idx_users_email ON users(email) USING hash;
```

**Example 2: Large table, range queries**
```sql
-- Table size: 1,000,000 rows
-- Query: Find orders by date range (100k rows expected)
CREATE INDEX idx_orders_date ON orders(order_date);
```

**Example 3: Composite index patterns**
```sql
-- Table with both exact and range queries on same columns
CREATE INDEX idx_products_composite ON products(category_id, price);
-- Supports: WHERE category_id = 5 (uses index prefix)
-- Supports: WHERE category_id = 5 AND price > 100 (uses index)
-- Supports: WHERE category_id = 5 ORDER BY price (uses index order)
```

## Performance Tips

### Choose the Right Index Type

| Use Case | Recommended Index |
|----------|-------------------|
| Exact-match lookups | Hash index |
| Range queries & ordering | B+Tree index |
| Both equality and range | B+Tree index |
| Very selective predicates | No index (sequential scan) |
| Highly selective equality | Hash index for performance |

### Composite Indexes

```sql
-- Composite index for common query patterns
CREATE INDEX idx_products_category_price ON products(category_id, price);

-- Supports multiple query patterns:
-- WHERE category_id = 1;
-- WHERE category_id = 1 AND price > 50;
-- WHERE category_id = 1 AND price BETWEEN 10 AND 100;
-- WHERE category_id = 1 ORDER BY price;  -- Uses index order
```

### Index Maintenance Considerations

**Write Performance Impact:**
- **Each INSERT:** Updates all indexes on the table
- **Each UPDATE:** Updates all indexes on modified columns
- **Each DELETE:** Removes entries from all indexes
- **Solution:** Balance index usage against write-heavy workloads

**Storage Requirements:**
- **Primary B+Tree:** ~20% overhead for tree structure
- **Secondary indexes:** Additional storage per indexed column
- **Hash indexes:** Variable overhead based on hash table size

### Index Selection Guidelines

**Create indexes when:**
- Table has > 1,000 rows
- Query uses same indexed column in WHERE clause repeatedly
- Query returns small result sets
- Index reduces disk I/O significantly

**Avoid indexes when:**
- Table < 1,000 rows (sequential scan faster)
- Columns used in user-defined functions or expressions
- Columns used only in INSERT (writes increase)
- Queries are highly unpredictable or complex

### Monitoring Index Usage

SimpleDB provides execution statistics through the query planner:

```sql
EXPLAIN SELECT * FROM users WHERE email = 'user@example.com';
```

**Expected output with hash index:**
```
-> HashIndexScan on users
   -> Predicate: email = 'user@example.com'
   -> Index size: 10,000 entries
   -> Estimated rows: 1
```

## Advanced Indexing Scenarios

### Index Fragmentation

**Prevention:**
- Rebuild indexes periodically if using B+Tree
- Monitor index usage patterns
- Adjust index composition based on query patterns

**Signs of fragmentation:**
- Slower query performance over time
- Increased I/O operations
- Large index sizes relative to table size

## Integration with Query Features

### Joins and Index Usage

**Nested Loop Joins:**
- Optimized when outer table has selective predicate using index
- Inner table full scan when no suitable index

**Hash Joins:**
- Build hash table on smaller table (preferably indexed)
- Probe with larger table

**Sort-Merge Joins:**
- Benefit from indexes on join columns for ordered access
- May use index to avoid separate sorting phase

### Aggregation Optimization

```sql
CREATE INDEX idx_sales_date ON sales(order_date);

EXPLAIN SELECT department_id, COUNT(*), AVG(salary)
FROM employees
GROUP BY department_id;
```

**Optimizer may use:** Index scan on indexed columns + aggregation optimization

## See Also

- [Features: Query Operations](query_operations.md) - Detailed explanation of how different query operators utilize indexes
- [Features: SQL Reference](sql_reference.md) - SQL syntax for CREATE INDEX and index management
- [Implementation: B+Tree](../implementation/storage/btree.md) - Technical details of B+Tree implementation
- [Implementation: Hash Index](../implementation/storage/hash_index.md) - Technical details of hash index implementation
- [Storage](storage.md) - Page layout details

## Trade-offs Summary

| Feature | B+Tree Index | Hash Index | None |
|---------|--------------|------------|------|
| **Lookup Speed** | Good (log n) | Excellent (constant) | Poor (sequential) |
| **Range Queries** | Excellent | None | None |
| **Memory Usage** | Higher | Lower | None |
| **Update Cost** | High | Medium | None |
| **Storage Efficiency** | Good | Variable | None |
| **Concurrency** | High | High | High |

## When to Rebuild Indexes

```sql
-- For SimpleDB, index rebuilding would be performed via:
-- 1. Taking table offline (if production)
-- 2. Dumping data to temporary storage
-- 3. Dropping and recreating all indexes
-- 4. Loading data back with new indexes

-- Schedule: Monthly or when fragmentation exceeds threshold
```

Index usage is crucial for SimpleDB's performance, but each type has its strengths and weaknesses. Choose wisely based on your specific query patterns and access requirements.