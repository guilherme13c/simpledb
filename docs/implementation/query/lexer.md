# Lexer Implementation

## Overview

The SimpleDB lexer (`src/query/lexer.zig`) is a hand-written, single-pass tokenizer that converts raw SQL text into a stream of `Token` structures for the parser. It operates directly on a `[]const u8` input buffer and maintains a `pos` cursor. The design prioritizes simplicity and zero external dependencies.

## Token Structure

```zig
pub const Token = struct {
    token_type: TokenType,
    text: []const u8,       // slice into original input (no allocation)
};
```

Tokens reference the original input via slices — no string allocation occurs during tokenization. This keeps the lexer fast and memory-efficient.

## Token Types

The `TokenType` enum covers all SQL elements recognized by the lexer:

### DDL Keywords
| Token | Keyword |
|-------|---------|
| `KeywordAlter` | ALTER |
| `KeywordAdd` | ADD |
| `KeywordRename` | RENAME |
| `KeywordColumn` | COLUMN |
| `KeywordTo` | TO |
| `KeywordCreate` | CREATE |
| `KeywordTable` | TABLE |
| `KeywordIndex` | INDEX |
| `KeywordDrop` | DROP |

### DML Keywords
| Token | Keyword |
|-------|---------|
| `KeywordInsert` | INSERT |
| `KeywordInto` | INTO |
| `KeywordValues` | VALUES |
| `KeywordSelect` | SELECT |
| `KeywordFrom` | FROM |
| `KeywordWhere` | WHERE |
| `KeywordAnd` | AND |
| `KeywordDelete` | DELETE |
| `KeywordUpdate` | UPDATE |
| `KeywordSet` | SET |

### Transaction & Control
| Token | Keyword |
|-------|---------|
| `KeywordBegin` | BEGIN |
| `KeywordCommit` | COMMIT |
| `KeywordRollback` | ROLLBACK |
| `KeywordPrepare` | PREPARE |
| `KeywordExplain` | EXPLAIN |
| `KeywordWith` | WITH |
| `KeywordAs` | AS |

### Data Type Keywords
| Token | Keyword |
|-------|---------|
| `KeywordInt` | INT |
| `KeywordVarchar` | VARCHAR |
| `KeywordBool` | BOOL |
| `KeywordFloat` | FLOAT |
| `KeywordTimestamp` | TIMESTAMP |
| `KeywordJson` | JSON |
| `KeywordUuid` | UUID |
| `KeywordSignedInt` | SIGNED_INT |

### Aggregate/Window Function Keywords
| Token | Keyword |
|-------|---------|
| `KeywordCount` | COUNT |
| `KeywordSum` | SUM |
| `KeywordMin` | MIN |
| `KeywordMax` | MAX |
| `KeywordAvg` | AVG |
| `KeywordOver` | OVER |
| `KeywordPartition` | PARTITION |
| `KeywordRowNumber` | ROW_NUMBER |
| `KeywordRank` | RANK |

### Clause & Join Keywords
| Token | Keyword |
|-------|---------|
| `KeywordGroup` | GROUP |
| `KeywordBy` | BY |
| `KeywordOrder` | ORDER |
| `KeywordAsc` | ASC |
| `KeywordDesc` | DESC |
| `KeywordLimit` | LIMIT |
| `KeywordOffset` | OFFSET |
| `KeywordJoin` | JOIN |
| `KeywordOn` | ON |
| `KeywordLeft` | LEFT |
| `KeywordRight` | RIGHT |
| `KeywordFull` | FULL |
| `KeywordOuter` | OUTER |
| `KeywordNull` | NULL |
| `KeywordUsing` | USING |
| `KeywordHash` | HASH |
| `KeywordBtree` | BTREE |
| `KeywordHaving` | HAVING |

### Literals & Identifiers
| Token | Description |
|-------|-------------|
| `Identifier` | Column/table names, aliases |
| `Number` | Integer or floating-point literals |
| `String` | Single-quoted string literals |

### Punctuation
| Token | Symbol |
|-------|--------|
| `LParen` | `(` |
| `RParen` | `)` |
| `Comma` | `,` |
| `Semicolon` | `;` |
| `Equals` | `=` |
| `NotEquals` | `!=` |
| `GreaterThan` | `>` |
| `GreaterEquals` | `>=` |
| `LessThan` | `<` |
| `LessEquals` | `<=` |
| `Asterisk` | `*` |

### Special
| Token | Description |
|-------|-------------|
| `EOF` | End of input |
| `Error` | Unrecognized character sequence |

## Lexer Algorithm

```zig
pub fn next_token(self: *Lexer) Token {
    skip_whitespace();
    if (pos >= input.len) return EOF;

    c = input[pos];

    // 1. Single-char punctuation (direct match)
    switch (c) { ... }

    // 2. Multi-char operators (>, <, !, etc.)
    if (c == '>' and peek == '=') return GreaterEquals;
    // ... similar for <=, !=

    // 3. String literals
    if (c == '\'') { read until closing '; return String; }

    // 4. Numeric literals
    if (is_digit(c)) { read digits; if (peek == '.') read fractional; return Number; }

    // 5. Identifiers & Keywords
    if (is_alpha(c)) {
        read while alnum/underscore/dot;
        text = input[start..pos];
        // Case-insensitive keyword lookup (linear chain)
        if (case_insensitive_eq(text, "SELECT")) return KeywordSelect;
        // ... 60+ if-checks
        return Identifier;
    }

    // 6. Unknown char
    pos += 1;
    return Error;
}
```

### Key Implementation Details

**Whitespace handling** (`skip_whitespace`): Consumes space, tab, newline, carriage return. No special handling for comments — SQL comments are not supported.

**Number parsing**: Recognizes integer (`123`) and float (`3.14`, `.5`) forms. No exponent notation (`1e10`), no underscores, no hex/bin prefixes.

**String parsing**: Single quotes only (`'hello'`). No escape sequences — a quote inside a string terminates it. Empty strings (`''`) are valid.

**Identifier parsing**: `[A-Za-z][A-Za-z0-9_.]*` — allows dots for qualified names (`table.column`). Underscores permitted.

**Keyword matching**: Linear chain of `case_insensitive_eq` calls (~65 comparisons). Case folding done per-character: `a-z` → `A-Z` by subtracting 32. No keyword table / trie.

**Error recovery**: On unrecognized char, consumes exactly one byte and emits `Error`. Parser can decide whether to panic or synchronize.

## Trade-offs

| Aspect | Choice | Rationale |
|--------|--------|-----------|
| **Keyword lookup** | Linear if-chain | ~65 keywords — negligible overhead; avoids hash table init |
| **Case sensitivity** | Keywords case-insensitive, identifiers case-sensitive | Matches PostgreSQL behavior; `case_insensitive_eq` is fast |
| **String escapes** | None | Simplicity; application layer handles escaping if needed |
| **Comment support** | None | Kept minimal; could add `--` or `/* */` later |
| **Token text** | Input slices | Zero allocation; lifetime tied to input buffer |
| **EOF handling** | Explicit token | Parser knows when input exhausted without special logic |

## Parser Integration

The parser (`src/query/parser.zig`) constructs a `Lexer` and calls `next_token()` repeatedly, building the AST. The lexer has no state beyond `pos` — it's stateless between calls. Tokens are consumed sequentially; no pushback/lookahead beyond single-character peek for multi-char operators.

## Limitations & Future Work

- No SQL comments (`--`, `/* */`)
- No parameter placeholders (`?`, `$1`, `:name`)
- No hex/binary literals
- No exponent notation in numbers
- Keyword list not extensible without recompilation
- Linear keyword lookup could become a bottleneck with many more keywords

## Related Files

- [`parser.md`](parser.md) — How tokens are consumed into AST nodes
- [`ast.md`](ast.md) — AST node definitions produced from tokens
- `src/query/lexer.zig` — Implementation