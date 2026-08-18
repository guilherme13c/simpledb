# Feature: Slotted Pages

## Location
`src/storage/page/slotted_view.zig`

## Overview
A naive approach to storing records on a page would be to simply append them sequentially. However, to support variable-length strings, efficient deletions, and updates without breaking external pointers, SimpleDB uses the industry-standard **Slotted Page** layout.

## Mechanics
- **Tuples (Data):** When a new tuple is inserted, it is placed at the *upper* (end) boundary of the page's available space, growing downwards.
- **Slots (Metadata):** For every tuple, a fixed-size `Slot` containing the `offset` and `length` is inserted at the *lower* (start) boundary of the page's space, growing upwards.
- **Record IDs (RID):** A record's external identifier (RID) relies on the slot index, not the physical byte offset. If a tuple is updated or compacted, its physical location can change, but as long as the `Slot` points to the new offset, the external RID remains perfectly valid.
