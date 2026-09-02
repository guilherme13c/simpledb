# Logical WAL replication

Source: `src/server/replication.zig`.

The normal replication path is a raw TCP stream. A follower sends
`START_REPLICATION <local WAL end>`. The leader waits on `LogManager.cond` when
the requested LSN is at its end, then sends complete WAL header/payload pairs
from that offset. The follower writes each record at its recorded LSN, advances
its local end offsets, and applies only `logical_insert` and `logical_delete`.

The table is found by matching the record's `page_id` to a current primary-tree
root ID. A logical insert payload is an eight-byte little-endian key plus tuple
bytes; delete is an eight-byte key. A record for root 0 triggers catalog reload
after application. Physical records are copied but not applied.

Although `read_acks_loop` can parse `ACK <lsn>` and feed the server's quorum
map, this stream does not start that loop and the follower does not emit ACKs.
There is no framing checksum, reconnect/resume repair, fsync acknowledgement,
membership validation, or authentication. Replication should therefore be
treated as experimental and asynchronous.
