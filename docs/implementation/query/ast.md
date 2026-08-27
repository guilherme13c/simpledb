# AST (Abstract Syntax Tree) Implementation

## Overview

The AST (`src/query/ast.zig`) defines all data structures that represent parsed SQL queries. It uses Zig's tagged unions (`union(enum)`) to model the hierarchical nature of SQL statements. Each statement type corresponds to a variant in the top-level `Statement` union. The AST is the output of the parser and the input to the executor.

## Data Types

```zig
pub const DataType = enum {
    int, varchar, bool, float, timestamp, json, uuid, signed_int,
};
```

These are the column type declarations used in `CREATE TABLE` and for schema metadata.

## Value Type

```zig
pub const ValueType = enum {
    int, varchar, bool, float, timestamp, json, uuid, signed_int, null_val,
};

pub const Value = union(ValueType) {
    int: u64,
    varchar: []const u8,
    bool: bool,
    float: f64,
    timestamp: i64,
    json: []const u8,
    uuid: [16]u8,
    signed_int: i64,
    null_val: void,
};
```

`Value` represents literal values that appear in `INSERT` rows, `WHERE` clauses, and output tuples. Note the asymmetry: `int` uses unsigned `u64` while `signed_int` uses signed `i64`. The `null_val` variant carries `void` (no data) and is distinct from a zero-value field.

## Column Definitions

```zig
pub const ColumnDef = struct {
    name: []const u8,
    data_type: DataType,
};
```

Used in `CREATE TABLE` to declare each column's name and type.

## Join Types

```zig
pub const JoinType = enum {
    inner, left, right, full,
};
```

SQL join kinds. No cross join or natural join variants.

## Conditions & Index Hints

```zig
pub const ConditionType = enum { eq, range };

/// Internal condition used by IndexScanExecutor for B-Tree lookups.
pub const Condition = union(ConditionType) {
    eq: struct { key: u64 },
    range: struct { start: u64, end: u64 },
};
```

`Condition` is a storage-internal representation extracted from an `Expression` by `try_extract_index_condition` in `executor.zig`. It is **not** what appears in the AST from the parser — it is a derived, execution-friendly form for the index scan operator. The `eq` variant maps a single key; `range` maps `[start, end]` inclusive bounds on the primary key column.

## Comparison Operations

```zig
pub const CompareOp = enum {
    eq, neq, gt, gte, lt, lte,
};
```

Comparison operators for use in `Expression`. All six operators are available for numeric and string types; only `eq` and `neq` are meaningful for `bool`, `json`.

## Expressions

```zig
pub const ExpressionType = enum {
    compare,           // column op literal_value
    column_compare,    // column op column
    and_expr,          // expr AND expr
    compare_subquery,  // column op (SELECT ...)
};

pub const Expression = union(ExpressionType) {
    compare: struct {
        column: []const u8,
        op: CompareOp,
        value: Value,
    },
    column_compare: struct {
        left_column: []const u8,
        op: CompareOp,
        right_column: []const u8,
    },
    and_expr: struct {
        left: *const Expression,
        right: *const Expression,
    },
    compare_subquery: struct {
        column: []const u8,
        op: CompareOp,
        subquery: *Statement,
    },
};
```

Expressions appear in `WHERE` clauses (`.condition`) and `ON` clauses (`.join_condition`). The `column_compare` variant handles `t1.col = t2.col` predicates in joins. The `compare_subquery` variant stores a pointer to the inner `Statement`; it is evaluated by a separate sub-plan at runtime.

## Aggregate Expressions

```zig
pub const AggregateOp = enum { count, sum, min, max, avg };

pub const AggregateExpr = struct {
    op: AggregateOp,
    column: ?[]const u8, // null for count(*)
};
```

Aggregate expressions appear in `SELECT` column lists alongside regular column references.

## Alter Actions

```zig
pub const AlterActionType = enum {
    add_column, drop_column, rename_column,
};

pub const AlterAction = union(AlterActionType) {
    add_column: ColumnDef,
    drop_column: []const u8,
    rename_column: struct { old_name: []const u8, new_name: []const u8 },
};
```

## Window Functions

```zig
pub const WindowFuncType = enum {
    row_number, rank, sum, count,
};

pub const WindowFunctionExpr = struct {
    func: WindowFuncType,
    arg_column: ?[]const u8,
    partition_by: ?[]const u8,
    order_by: ?[]const u8,
    is_desc: bool,
};
```

Window function descriptors parsed from `OVER (PARTITION BY ... ORDER BY ...)`. Only `row_number`, `rank`, `sum`, `count` are implemented.

## Common Table Expressions

```zig
pub const Cte = struct {
    name: []const u8,
    statement: *Statement,
};
```

A named subquery for `WITH name AS (select) ...` syntax. The parser resolves the inner statement and stores a pointer to it.

## Index Types

```zig
pub const IndexType = enum { btree, hash };
```

Index method for `CREATE INDEX`. B-Tree supports range scans; Hash supports equality only.

## Order By Expressions

```zig
pub const OrderByExpr = struct {
    column: []const u8,
    is_desc: bool,
};
```

A single sort key. `ORDER BY col1 ASC, col2 DESC` maps to a slice of `OrderByExpr`.

## Top-Level Statements

```zig
pub const StatementType = enum {
    create_table, create_index, drop_table, alter_table,
    insert, select, delete, update,
    begin, commit, rollback, prepare,
    explain, with,
};

pub const Statement = union(StatementType) {
    create_table:   struct { table_name: []const u8, columns: []const ColumnDef },
    create_index:    struct { index_name, table_name, column_name, index_type },
    drop_table:     struct { table_name: []const u8 },
    alter_table:    struct { table_name, action },
    insert:         struct { table_name: []const u8, values: []const Value },
    select:         SelectStmt,
    delete:         DeleteStmt,
    update:         UpdateStmt,
    begin:          void,
    commit:         void,
    rollback:       void,
    prepare:        void,
    explain:        *Statement,
    with:           WithStmt,
};
```

### Select Statement

```zig
const select: SelectStmt = struct {
    columns:            ?[]const []const u8,   // null means *
    aggregates:        ?[]const AggregateExpr,
    window_functions:  ?[]const WindowFunctionExpr,
    table_name:        []const u8,
    join_type:         JoinType,
    join_table:        ?[]const u8,
    join_condition:    ?Expression,
    condition:         ?Expression,   // WHERE
    group_by:          ?[]const u8,   // single column for now
    order_by:           ?[]const OrderByExpr,
    limit:             ?usize,
    offset:            ?usize,
};
```

Notable: `columns` is `null` for `SELECT *` and a nested array for explicit column lists. `group_by` is restricted to a single column. `limit`/`offset` are plain `usize` values parsed from literal numbers.

### Update Statement

```zig
update: struct {
    table_name:   []const u8,
    column_name:  []const u8,
    value:        Value,
    condition:    ?Expression,
},
```

Note: `UPDATE` only supports setting one column at a time (`SET col = value`). Multi-column updates require multiple statements.

## How the Parser Produces the AST

The parser (documented in [`parser.md`](parser.md)) invokes the lexer token-by-token and builds `Statement` instances through recursive descent. Key transformations:

1. **Keywords → Statement variant**: A leading keyword (`SELECT`, `INSERT`, etc.) dispatches to the corresponding parsing function.
2. **Expression parsing**: Infix comparison operators are parsed into `Expression` nodes. `AND` chains become nested `and_expr` nodes (right-associative via the recursive call structure).
3. **Literal type inference**: Number tokens in `WHERE` or `VALUES` are parsed into the appropriate `Value` variant based on context — `INT` vs `SIGNED_INT` vs `FLOAT`.
4. **Condition → Condition extraction**: The executor, not the parser, converts a simple `Expression` into an internal `Condition` for index scans. This happens in `executor.zig:try_extract_index_condition`.
5. **Schema lookup deferred**: Column name resolution (`resolve_column` in `executor.zig`) is done at execution time against the live `Table.schema`, not at parse time. The parser only stores column names as strings.

## Design Trade-offs

| Aspect | Choice | Trade-off |
|--------|--------|-----------|
| **Expression tree** | Tagged union per variant | Exhaustiveness enforced by Zig compiler; adding a new operator requires updating every `switch` over `Expression` |
| **Value storage** | Slices for `varchar`/`json` | Zero-copy from lexer text; lifetime must outlive the AST (managed by arena or single-query lifetime) |
| **Subquery storage** | `*Statement` pointer | Enables cyclic AST for `SELECT IN (SELECT ...)`; lifetime management critical |
| **Column resolution** | Runtime lookup | Flexible schema changes; slower than parse-time binding |
| **Join predicates** | Single `Expression` on `ON` | Multi-predicate joins must be expressed as `AND` |
| **Single-column GROUP BY** | String slice | Easy to extend to `[]const []const u8` later |

## Related Files

- [`lexer.md`](lexer.md) — Token production from SQL text
- [`parser.md`](parser.md) — How the parser assembles AST nodes from tokens
- [`executor.md`](executor.md) — How AST nodes are compiled into execution plans
- `src/query/ast.zig` — Implementation