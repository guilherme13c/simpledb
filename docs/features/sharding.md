# Sharding

SimpleDB uses consistent-hashing sharding with virtual nodes. Queries are routed or scatter-gathered across shards via TCP protocol; replication layers on top via Raft.

## Configuration

Launch each shard with CLI flags:
```bash
./simpledb --port 8080 --num-shards 2 --shard-id 0
./simpledb --port 8081 --num-shards 2 --shard-id 1 --seed 127.0.0.1:8080
```
- `num-shards`: total shard count (ring size fixed at runtime)
- `shard-id`: this node's identity
- `seed`: first node for gossip discovery; others join via gossip (`gossip.zig`)

## Ring Design

`ConsistentHashRing` (`src/server/consistent_hash.zig`) maintains sorted virtual nodes (`vnode: hash + physical_node`). Default 10 vnodes per physical node via `vnodes_per_physical`. Routing uses binary search on Wyhash; wrap-around handled at end of array.

Virtual node keys are `"node#i"` (e.g., `"nodeA#0"`). Removing a physical node deletes all its vnodes; remapping only touches keys previously owned by those vnodes (minimal movement).

## ROUTER REPL Commands (TCP)

Over TCP connection (`connection.zig`):

```text
ROUTER ADD nodeB
ROUTER REMOVE nodeB
ROUTER GET user_1
```
- `ADD`: inserts 10 virtual nodes for `nodeB`; ring sorted
- `REMOVE`: deletes all vnodes for `nodeB`
- `GET`: binary-searches ring for `key`, returns owning node (or `ERR no nodes`)

Example mapping:
```text
ROUTER GET user_1  -> nodeA
ROUTER GET order_99 -> nodeC
```

## Query Routing

- `SELECT`/`INSERT`/`UPDATE`/`DELETE` executed by `execute_statement` (`execution.zig`) against local catalog
- If key-based, router can direct to owning shard; full-table scans use scatter-gather (see below)
- Each shard is independent server with its own catalog, WAL, and replication

## Scatter-Gather Queries

Queries with no key restriction (e.g., `SELECT * FROM shard_test;`) are broadcast to all shards via gossip/connection logic; results merged client-side (tested in `tests/integration/test_sharding.py`: 2 rows from 2 shards returned as 3-line result with OK).

Integration with replication: each shard runs Raft (`src/server/raft.zig`) and replicates writes; sharding distributes data, replication ensures durability within shard.

## Key-to-Shard Mapping Example

```zig
var ring = ConsistentHashRing.init(allocator, 10);
try ring.add_node("nodeA");
try ring.add_node("nodeB");
const n = ring.get_node("user_1");  // -> nodeA/nodeB by hash
```

Topology changes (`add_node`/`remove_node`) rebalance with only ~1/N key movement due to virtual-node smoothing.

## Integration with Replication

- Shard nodes use `RAFT_CONFIG_UPDATE` for cluster membership
- `START_REPLICATION ` serves replication stream (`replication.zig`)
- Gossip (`gossip.zig`) propagates topology and WFG edges; consistent hash ring updated via ROUTER commands
- Quorum (`quorum_mutex`) ensures writes durable on shard before acknowledging

## Links
- Implementation: `implementation/consistent_hash.md`, `implementation/gossip.md`
- Replication: `features/replication.md`
- Storage/catalog: `features/storage.md`
