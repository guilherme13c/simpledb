# Leader-Follower Logical Replication

SimpleDB implements a **leader-follower logical replication** model built on top of Raft consensus. The leader acts as the single source of truth for all writes, while followers replicate those writes and serve read-only queries.

## Overview

| Component | Role |
|-----------|-------|
| **Leader** | Accepts writes, orders them in the WAL, and propagates them to followers |
| **Followers** | Receive logical WAL records, apply them to local state, and serve read-only queries |
| **Raft Group** | Manages leader election, configuration updates, and log replication |
| **Gossip Protocol** | Maintains peer membership and health information |

## Write Path

1. **Client → Leader** – A client submits a write (INSERT, UPDATE, DELETE, or DDL) to the leader.
2. **Leader Appends to WAL** – The leader appends the write as a *logical record* to its Write-Ahead Log (WAL) and assigns a monotonically increasing Log Sequence Number (LSN).
3. **Leader Broadcasts** – The leader sends a `RAFT_APPEND_ENTRIES` message to every follower over a dedicated replication stream. Each message contains:
   - Term (Raft epoch)
   - Previous LSN (to ensure followers catch up)
   - Base64-encoded payload of the logical record
4. **Follower Application** – Each follower receives the message, deserializes the payload, and applies the logical record to its local state (tables, WFG edges, etc.).
5. **Consistency Guarantee** – Because all writes go through the leader and are ordered by LSN, followers always converge to the same state. Reads are served from the local state after the follower has caught up to the latest committed LSN.

## Read Path

- **Followers are read-only** – They never accept writes; they simply apply replicated logical records and serve queries from their local state.
- **Horizontal scaling** – Adding or removing followers increases read capacity without affecting write availability. The leader continues to handle all writes and replication.
- **Query routing** – Clients can direct read traffic to any follower; the system routes reads to followers that have caught up to the latest LSN.

## Follower Read Scaling

Because followers are immutable readers, they can be scaled horizontally:

- **Independent scaling** – Each follower can handle its own query load; the leader remains the sole coordinator.
- **Load distribution** – Requests are routed to followers whose local state is up‑to‑date. The system tracks follower LSNs and serves reads only to followers that have caught up to the current commit LSN.
- **No write contention** – Since followers never accept writes, there is no write amplification or hotspot.

## RAFT_CONFIG_UPDATE for Topology Changes

Topology changes (adding or removing members) are handled through Raft's configuration mechanism:

1. **Proposal** – The leader proposes a `RAFT_CONFIG_UPDATE` message containing the new member list (or removal list) and the desired state transition.
2. **Replication** – All followers receive the message and must acknowledge it. Only when a majority (quorum) of replicas have accepted the change does the leader consider the configuration applied.
3. **State transition** – Once the configuration is committed, the WFG (Work‑Flow Graph) is rebuilt to reflect the new peer set. The leader then begins replicating the updated membership to all followers.
4. **Membership changes** – During an election, a candidate may propose a new configuration (e.g., changing the leader address). If the candidate wins, the new configuration is applied atomically.

## How Replication Works (Step‑by‑Step)

```
Client                              Leader                          Followers
   |                                     |                               |
   |-- INSERT / UPDATE / DELETE --------->|                               |
   |                                     |-- Append to WAL (LSN N) ---->|                               |
   |                                     |-- Send RAFT_APPEND_ENTRIES(N) |                               |
   |<-- ACK (optional) -----------------|                               |                           |
   |                                     |-- Apply logical record ---->|                               |
   |                                     |-- Update local state          |                               |
   |<-- ACK (optional) -----------------|                               |                           |
```

- **Logical vs. Physical** – Writes are logged logically (operation + key + value) rather than physically. This allows the leader to reorder or compress records before sending them to followers.
- **Base64 encoding** – Payloads are base64‑encoded for safe transport over TCP.
- **Heartbeats** – The leader periodically sends `RAFT_HEARTBEAT` messages to keep followers alive and to detect failures quickly.

## Monitoring

- **LSN Tracking** – Each node tracks its highest processed LSN. Followers report their LSN to the leader; the leader advances the LSN only after all followers have caught up.
- **Gossip Protocol** – The gossip layer maintains a `Peer` registry (address, last seen timestamp, shard ID). It helps detect dead followers and informs the leader about topology changes.
- **Raft Election Loop** – If the leader fails, followers increment their term, start an election, and eventually elect a new leader. The new leader rebuilds the WFG and resumes replication.
- **Metrics** – Key observables include:
  - **LSN lag** – Difference between leader LSN and follower LSN
  - **Replication throughput** – WAL records per second per leader
  - **Follower count** – Total number of active replicas
  - **Configuration change events** – Number of `RAFT_CONFIG_UPDATE` messages

## Example Flow

1. **Startup** – The leader initializes the Raft group, creates gossip peers, and opens the replication stream to each follower.
2. **Write** – A client inserts a row. The leader appends a logical record `{type: INSERT, key: row_id, value: row_data}` with LSN = N.
3. **Replication** – The leader sends `RAFT_APPEND_ENTRIES{N, LSN=N, payload=...}`. Each follower applies the insert to its table.
4. **Read** – A query for `SELECT * FROM users WHERE id = ?` is routed to any follower that has LSN ≥ N. The follower returns the result.
5. **Topology change** – If a new node joins, the leader proposes a `RAFT_CONFIG_UPDATE` with the new peer list. Once a quorum agrees, the WFG is rebuilt and the new configuration is active.

## Summary

- **Leader** – Single writer, orders writes in WAL, broadcasts logical records.
- **Followers** – Read‑only replicas that apply logical records and serve queries.
- **Replication** – Leader → followers via dedicated TCP stream; uses LSN ordering for consistency.
- **Scaling** – Horizontal scaling of reads by adding followers; writes remain centralized.
- **Topology changes** – Handled via Raft configuration updates, requiring quorum agreement.
- **Monitoring** – LSN lag, heartbeats, gossip membership, and election metrics provide visibility into the replication state.
