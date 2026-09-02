# Server architecture

Source: `src/server/server.zig`.

`Server` owns the catalog reference, logger, lock manager, transaction-ID
counter and active-ID map, an in-memory consistent-hash ring, optional gossip
and Raft objects, and replication/quorum bookkeeping. `start` starts gossip and
Raft, starts a follower's logical-replication thread when a leader address was
configured, then listens on `127.0.0.1:<port>` and detaches one thread per TCP
connection.

The server has locks for active transactions, DDL/read coordination, WFG
state, and quorum acknowledgements. `checkpointer_loop` and
`wfg_detector_loop` are defined but are not spawned by `Server.start`; buffer
manager flushing is started by the storage bootstrap instead. The in-memory
consistent-hash ring is controlled through `ROUTER` commands and is not used to
route SQL requests.
