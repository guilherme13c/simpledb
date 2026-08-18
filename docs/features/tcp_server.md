# Feature: TCP Server

## Location
`src/server/server.zig`

## Overview
SimpleDB operates primarily over a custom, multi-threaded TCP server architecture. To handle thousands of connections efficiently without hitting standard blocking walls, the server completely utilizes Zig 0.16.0's `std.Io` framework.

## Protocol
The server implements a human-readable, space-delimited text protocol:
- **`CREATE <table_name>`**: Instructs the catalog to allocate a new B+Tree root and table structure.
- **`DROP <table_name>`**: Deletes a table mapping.
- **`PUT <table_name> <key> <data>`**: Inserts the payload into the table's slotted pages and inserts a reference into the B+Tree.
- **`GET <table_name> <key>`**: Fetches a specific payload.
- **`SCAN <table_name> <start_key> <end_key>`**: Iterates through the B+Tree leaf nodes to retrieve a range of data sequentially.

## Threading
When a client connects, the event loop spawns a dedicated handler routine utilizing `std.Io.Threaded`. This ensures the main listener is never blocked while queries are parsed or disk blocks are fetched.
