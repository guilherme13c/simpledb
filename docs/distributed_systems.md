# Distributed Systems

SimpleDB includes robust, fully-implemented distributed systems features allowing nodes to operate as clustered replicas or sharded environments.

## 1. Multi-Raft & Explicit Joint Consensus
SimpleDB implements a custom Multi-Raft architecture to handle replication.

- **TCP WAL Streaming:** Instead of traditional snapshot shipping, Leaders chunk and base64-encode physical WAL `LogRecord` segments, appending them seamlessly via TCP streams (`RAFT_APPEND_ENTRIES`).
- **Phase 3 Joint Consensus (`RAFT_CONFIG_UPDATE`):** 
  Topological cluster changes (adding or removing nodes) are executed securely via Explicit Joint Consensus ($C_{old,new}$).
  The leader dynamically shifts to a `.ColdNew` state, emits a `.raft_config_change` entry to its WAL, and replicates it. Followers unpack this WAL record over TCP and hot-reload their local `RaftGroup` topology without downtime.

## 2. Distributed Deadlock Detection
Instead of local wait-for graphs, SimpleDB employs Global Wait-For Graphs via Gossip.
If a transaction spans multiple nodes, wait chains are propagated over the Gossip protocol. A cycle anywhere in the global cluster graph triggers an immediate distributed abort mechanism.

## 3. Consistent Hashing (Sharding Ring)
SimpleDB includes a native Sharding Ring using Wyhash and Virtual Nodes (`VirtualNode`).
When the cluster topology changes, the `ConsistentHashRing` allows for dynamic query routing.
You can interact with the router via REPL:
- `ROUTER ADD {peer}`
- `ROUTER REMOVE {peer}`
- `ROUTER GET {table}#{primary_key}` (Determines the physical shard owner)

## 4. Jepsen-style Chaos Testing
The project features a full Python Chaos Harness (`tests/chaos_test_log.py`).
This harness automatically spins up multiple `simpledb` processes, injects `SIGSTOP` network partitions (killing both followers and Leaders mid-execution), and aggressively asserts that:
1. Multi-Raft successfully auto-elects a new leader maintaining 2/3 majority.
2. Unacknowledged writes fail safely.
3. Node recovery and state reconciliation remains 100% ACID compliant after the partition heals.
