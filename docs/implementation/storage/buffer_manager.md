# Buffer manager

Source: `src/storage/buffer_manager/buffer_manager.zig`.

The buffer pool contains 4096 `Frame`s. A frame has an optional page ID, page
bytes, pin count, dirty bit, 0..5 usage count, valid/empty state, a page
read/write latch, and an I/O mutex. A fixed 8192-bucket chained hash table maps
page ID to frame ID. The pool mutex protects the mapping and replacement state;
the I/O mutex makes fetchers wait until a read/write on the reused frame ends.

Misses use a clock hand. Each eligible unpinned frame loses one usage count per
inspection; initial sweeps avoid dirty victims while clean candidates exist,
signal the flusher for dirty candidates, and eventually permit a dirty victim.
The victim is removed from the map, WAL-flushed if dirty, written, then read or
zeroed for `new_frame`. Callers must unpin each returned frame; pinning is not
RAII-protected.

`start` launches two threads. Every roughly 10 ms the flusher batches up to 128
unpinned dirty frames, flushes WAL through the greatest page LSN, writes them,
and marks them clean even if the batch write failed (the error is discarded).
Sequential `fetch_frame` calls enqueue the next page after 32 consecutive IDs;
the prefetcher loads up to 32 pages per request through a 64-entry ring queue.
`checkpoint` synchronously writes dirty pages then appends a checkpoint record.
