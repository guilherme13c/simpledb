# Feature: SQL Query Parsing

## Location
`src/query/lexer.zig`
`src/query/parser.zig`
`src/query/ast.zig`
`src/server/server.zig`

## Overview
SimpleDB now utilizes a custom SQL parser to translate human-readable SQL strings into database operations. 

Previously, the TCP Server relied on a primitive space-delimited text protocol (e.g. `PUT users 1 alice`). With the introduction of the Query Parsing pipeline, SimpleDB now accepts a standard subset of SQL syntax.

## Implementation Details

The query pipeline executes in three main stages:

1. **Lexical Analysis (`lexer.zig`)**: 
   The `Lexer` scans incoming strings (TCP packets or WAL lines) and categorizes character sequences into distinct `Token` types (`KeywordSelect`, `Identifier`, `Number`, `Equals`, etc.). Keywords are evaluated case-insensitively.

2. **Parsing & Abstract Syntax Tree (`parser.zig`, `ast.zig`)**:
   The `Parser` consumes tokens and uses a recursive descent approach to construct an Abstract Syntax Tree (AST) node (`ast.Statement`). 
   It accurately groups constraints into a discrete `ast.Condition` union structure (supporting both exact equality and numeric range queries).

3. **Execution & Logical Logging (`server.zig`)**:
   The AST is processed by `Server.execute_statement()`, which acts as the execution engine bridging AST commands to the `Catalog` and `B+Tree` indices. 
   Mutating statements automatically serialize the exact original SQL text to the Write-Ahead Log (WAL), meaning that `simpledb.wal` now persists operations completely logically in plain SQL!

## Supported SQL Syntax
- `CREATE TABLE <table_name>;`
- `DROP TABLE <table_name>;`
- `INSERT INTO <table_name> VALUES (<key>, '<value>');`
- `DELETE FROM <table_name> WHERE key = <key>;`
- `SELECT * FROM <table_name> WHERE key = <key>;`
- `SELECT * FROM <table_name> WHERE key >= <start_key> AND key <= <end_key>;`
