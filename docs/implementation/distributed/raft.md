# Raft experiment

Source: `src/server/raft.zig`.

`RaftGroup` maintains an in-memory role, term, vote target, vote-name set,
last-heartbeat timestamp, and `ClusterConfig`. It sends vote requests and
heartbeats over the gossip UDP socket; vote responses are accepted only for a
candidate's current term. Election timeouts are randomly chosen from 1500 to
2999 ms, but the loop sleeps in whole seconds, so the effective timing is
coarse. A candidate votes for itself and becomes leader after the configured
majority (both old and new majorities in `ColdNew`).

Leaders also run a one-second TCP append loop. It reads at most the next WAL
record per peer, base64-encodes it, and sends `RAFT_APPEND_ENTRIES`. The
receiver writes those bytes at the recorded LSN and applies logical inserts or
config records. `next_index` is never advanced after a reply, replies are not
parsed by this loop, `prev_term` is ignored, and there is no commit index,
match index, log truncation, durable term/vote state, snapshot, or quorum-based
application. This is consequently not a complete Raft implementation.

`is_async_replica` suppresses the Raft threads. On a heartbeat or append entry
with a non-stale term, a node updates its leader address and marks itself a
replica.
