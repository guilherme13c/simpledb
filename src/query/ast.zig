const std = @import("std");

pub const DataType = enum {
    int,
    varchar,
    bool,
    float,
    timestamp,
    json,
    uuid,
    signed_int,
};

pub const ColumnDef = struct {
    name: []const u8,
    data_type: DataType,
};

pub const ValueType = enum {
    int,
    varchar,
    bool,
    float,
    timestamp,
    json,
    uuid,
    signed_int,
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
};

pub const ConditionType = enum {
    eq,
    range,
};

/// Internal condition used by IndexScanExecutor for B-Tree lookups.
pub const Condition = union(ConditionType) {
    eq: struct { key: u64 },
    range: struct { start: u64, end: u64 },
};

pub const CompareOp = enum {
    eq,
    neq,
    gt,
    gte,
    lt,
    lte,
};

pub const ExpressionType = enum {
    compare,
    column_compare,
    and_expr,
};

/// General expression for WHERE clauses. Can reference any column by name.
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
};

pub const AggregateOp = enum { count, sum, min, max, avg };

pub const AggregateExpr = struct {
    op: AggregateOp,
    column: ?[]const u8, // null for count(*)
};

pub const StatementType = enum {
    create_table,
    create_index,
    drop_table,
    insert,
    select,
    delete,
    update,
    begin,
    commit,
    rollback,
    explain,
};

pub const Statement = union(StatementType) {
    create_table: struct { table_name: []const u8, columns: []const ColumnDef },
    create_index: struct { index_name: []const u8, table_name: []const u8, column_name: []const u8 },
    drop_table: struct { table_name: []const u8 },
    insert: struct { table_name: []const u8, values: []const Value },
    select: struct { 
        columns: ?[]const []const u8, // null means '*'
        aggregates: ?[]const AggregateExpr,
        table_name: []const u8, 
        join_table: ?[]const u8,
        join_condition: ?Expression,
        condition: ?Expression,
        group_by: ?[]const u8, // single column group by for now
        order_by: ?[]const u8,
        is_desc: bool,
        limit: ?usize,
        offset: ?usize,
    },
    delete: struct { 
        table_name: []const u8,
        condition: ?Expression,
    },
    update: struct {
        table_name: []const u8,
        column_name: []const u8,
        value: Value,
        condition: ?Expression,
    },
    begin: void,
    commit: void,
    rollback: void,
    explain: *Statement,
};
