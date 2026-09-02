# Raft cluster configuration

Source: `src/server/raft_config.zig` and `RaftGroup.handle_config_update`.

`ClusterConfig` owns byte copies of `old_members`, optional `new_members`, and
one of two states: `Cold` or `ColdNew`. Its serialized, little-endian format is
`state:u8 | old_count:u32 | (member_len:u32 | member_bytes)* |
new_count:u32 | (member_len:u32 | member_bytes)*`. A zero new count
deserializes as `null`, so an explicitly empty new membership cannot be
distinguished from no proposed membership.

Only a leader accepts `RAFT_CONFIG_UPDATE add|remove <address>`. It derives a
new member list, replaces the in-memory config with `ColdNew`, writes a
`raft_config_change` WAL record, and forces it. There is no implementation of
the second transition from joint configuration back to a stable `Cold` config,
and no replication/commit acknowledgement before the local configuration
changes.
