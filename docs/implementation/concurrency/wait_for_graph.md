# Wait-for graph

Source: `src/storage/concurrency/wfg.zig`; collection is in
`LockManager.get_wait_for_edges` and distribution is in `src/server/server.zig`.

`GlobalWFG` is an allocator-owned flat `ArrayList(Edge { waiting, holding })`.
`add_edge` performs linear duplicate suppression. `detect_cycle` builds a set
of endpoint IDs then depth-first searches outgoing edges using `visited` and
recursion-stack hash maps. Encountering a stack node reports a cycle; the DFS
returns the maximum transaction ID encountered while unwinding, so that ID is
the selected victim rather than a cost-based choice.

The lock manager emits one edge from each ungranted request to every granted
request for the same resource owned by a different transaction. `Server` runs
a detector loop every two seconds, stores per-shard edge snapshots, broadcasts
them as unauthenticated `WFG_REPORT` gossip messages, builds a fresh graph, and
locally/broadcast-kills the selected victim. Snapshots replace the prior one
per shard; there is no epoch, expiration, authentication, or confirmation.
