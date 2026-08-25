# Query Parser Implementation

## Overview
SimpleDB implements a custom SQL subset using a hand-written lexer and recursive-descent parser. This provides full control over the query language without external dependencies.

## Lexer

### Token Types
```zig
pub const TokenType = enum {
    // Keywords
    KeywordSelect, KeywordFrom, KeywordWhere,
    KeywordInsert, KeywordInto, KeywordValues,
    KeywordUpdate, KeywordSet,
    KeywordDelete, KeywordFrom,
    KeywordCreate, KeywordTable, KeywordIndex,
    KeywordDrop, KeywordAlter, KeywordAdd, KeywordColumn,
    KeywordBegin, KeywordCommit, KeywordRollback, KeywordPrepare,
    KeywordExplain, KeywordWith, KeywordAs,
    KeywordUsing, KeywordHash, KeywordBtree,
    KeywordInt, KeywordVarchar, KeywordBool,
    KeywordFloat, KeywordTimestamp, KeywordJson,
    KeywordUuid, KeywordSignedInt, KeywordOn,

    // Operators
    Asterisk, Plus, Minus, Slash, Percent,
    Eq, Neq, Lt, Gt, Lte, Gte,
    And, Or, Not, In,

    // Delimiters
    LParen, RParen, Comma, Semicolon, Dot,

    // Literals
    Number, String, Identifier,

    // Special
    Eof, Unknown,
};
```

### Lexer Implementation
```zig
pub const Lexer = struct {
    input: []const u8,
    position: usize,

    pub fn next_token(self: *Lexer) Token { ... }

    fn skip_whitespace(self: *Lexer) void { ... }
    fn read_identifier(self: *Lexer) Token { ... }
    fn read_number(self: *Lexer) Token { ... }
    fn read_string(self: *Lexer) Token { ... }
};
```

## Abstract Syntax Tree (AST)

### Statement Types
```zig
pub const Statement = union(enum) {
    begin: void,
    commit: void,
    rollback: void,
    prepare: void,

    select: SelectStmt,
    insert: InsertStmt,
    update: UpdateStmt,
    delete: DeleteStmt,

    create_table: CreateTableStmt,
    create_index: CreateIndexStmt,
    drop_table: DropTableStmt,
    alter_table: AlterTableStmt,

    explain: *Statement,
    with: WithStmt,
};
```

### Data Types
```zig
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
```

## Parser Structure

### Parser Implementation
```zig
pub const Parser = struct {
    lexer: Lexer,
    current_token: Token,
    allocator: std.mem.Allocator,

    pub fn parse_statement(self: *Parser) !Statement { ... }
    fn match(self: *Parser, expected: TokenType) !void { ... }
    fn advance(self: *Parser) void { ... }
};
```

### Statement Parsing

#### SELECT Statement
```zig
fn parse_select(self: *Parser) !Statement {
    // SELECT * | columns
    // FROM table
    // WHERE condition
    // GROUP BY columns
    // ORDER BY columns
    // LIMIT n
}
```

#### INSERT Statement
```zig
fn parse_insert(self: *Parser) !Statement {
    // INSERT INTO table VALUES (values...)
    // OR INSERT INTO table SELECT ...
}
```

#### CREATE TABLE
```zig
fn parse_create(self: *Parser) !Statement {
    // CREATE TABLE name (col1 type, col2 type, ...)
}
```

#### CREATE INDEX
```zig
fn parse_create(self: *Parser) !Statement {
    // CREATE INDEX idx ON table (column) USING btree|hash
}
```

## Expression Parsing

### Operator Precedence
1. OR (lowest)
2. AND
3. NOT
4. comparison (=, !=, <, >, <=, >=)
5. + -
6. * / %
7. (highest)

### Binary Expressions
```zig
pub const Expr = union(enum) {
    binary: BinaryExpr,
    unary: UnaryExpr,
    column: []const u8,
    literal: Value,
    func: FuncExpr,
};

pub const BinaryExpr = struct {
    left: *Expr,
    op: TokenType,
    right: *Expr,
};
```

## Error Handling

### Parser Errors
```zig
pub const ParserError = error{
    UnexpectedToken,
    InvalidSyntax,
    InvalidNumber,
};
```

### Recovery Strategies
- Panic mode: Skip tokens until synchronization point
- Error tokens: Mark error location, continue parsing

## Trade-offs

### Advantages
- **No Dependencies**: Custom implementation, no external parser library
- **Full Control**: Can implement custom SQL dialect
- **Performance**: Tailored for SimpleDB's specific needs
- **Educational**: Clear implementation for learning

### Disadvantages
- **Maintenance**: All features must be implemented manually
- **Limited Features**: No advanced SQL features (CTEs, window functions, etc.)
- **Error Messages**: Less polished than production parsers

### Alternatives
1. **ANTLR**: Industry-standard parser generator
2. **yacc/bison**: LALR parser generators
3. **peg.js**: Parsing Expression Grammars
4. **Rust's pest**: PEG parser

## Performance
- Lexing: O(n) where n is query length
- Parsing: O(n) for most statements
- Memory: Proportional to AST depth