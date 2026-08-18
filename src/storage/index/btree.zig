const std = @import("std");
const page = @import("../page/page.zig");
const BufferManager = @import("../buffer_manager/buffer_manager.zig").BufferManager;
const Frame = @import("../buffer_manager/buffer_manager.zig").Frame;
const TransactionContext = @import("../wal/transaction.zig").TransactionContext;
const btree_node = @import("btree_node.zig");
const BTreeNodeView = btree_node.BTreeNodeView;

const SplitResult = struct {
    key: u64,
    right_child: u32,
};

pub const BTree = struct {
    buffer_manager: *BufferManager,
    root_page_id: u32,
    next_alloc_page_id: *u32, // Simple page allocator for our toy DB
    tree_latch: std.Io.RwLock,

    pub fn init(buffer_manager: *BufferManager, root_page_id: u32, next_free_page: *u32) !BTree {
        return .{
            .buffer_manager = buffer_manager,
            .root_page_id = root_page_id,
            .next_alloc_page_id = next_free_page,
            .tree_latch = .init,
        };
    }

    /// Allocates a new page ID (creates a logical hole in the file)
    fn allocate_page(self: *BTree) !u32 {
        const id = self.next_alloc_page_id.*;
        self.next_alloc_page_id.* += 1;
        return id;
    }

    /// Searches for a key in the B+Tree and returns its associated value (RID)
    pub fn search(self: *BTree, key: u64) !?u64 {
        const io = self.buffer_manager.storage_manager.io;
        self.tree_latch.lockSharedUncancelable(io);

        var current_frame = try self.buffer_manager.fetch_frame(self.root_page_id);
        current_frame.latch.lockSharedUncancelable(io);
        self.tree_latch.unlockShared(io);

        while (true) {
            var view = BTreeNodeView{ .raw = &current_frame.page };
            const meta = view.get_meta();

            if (meta.node_type == .leaf) {
                const result = view.leaf_search(key);
                current_frame.latch.unlockShared(io);
                self.buffer_manager.unpin_frame(current_frame, false);
                return result;
            } else {
                const next_child_id = view.internal_search(key);
                
                const next_frame = try self.buffer_manager.fetch_frame(next_child_id);
                next_frame.latch.lockSharedUncancelable(io);
                
                current_frame.latch.unlockShared(io);
                self.buffer_manager.unpin_frame(current_frame, false);
                
                current_frame = next_frame;
            }
        }
    }

    /// Scans for keys in the range [start_key, end_key] and returns their RIDs
    pub fn scan(self: *BTree, allocator: std.mem.Allocator, start_key: u64, end_key: u64) ![]u64 {
        const io = self.buffer_manager.storage_manager.io;
        self.tree_latch.lockSharedUncancelable(io);
        var rids = std.ArrayList(u64).empty;
        
        var current_frame = try self.buffer_manager.fetch_frame(self.root_page_id);
        current_frame.latch.lockSharedUncancelable(io);
        self.tree_latch.unlockShared(io);
        
        while (true) {
            var view = BTreeNodeView{ .raw = &current_frame.page };
            const meta = view.get_meta();

            if (meta.node_type == .leaf) {
                break;
            } else {
                const next_child_id = view.internal_search(start_key);
                
                const next_frame = try self.buffer_manager.fetch_frame(next_child_id);
                next_frame.latch.lockSharedUncancelable(io);
                
                current_frame.latch.unlockShared(io);
                self.buffer_manager.unpin_frame(current_frame, false);
                
                current_frame = next_frame;
            }
        }
        
        while (true) {
            var view = BTreeNodeView{ .raw = &current_frame.page };
            const meta = view.get_meta();
            const elements = view.get_leaf_elements();
            
            var i: usize = 0;
            var stop = false;
            while (i < elements.len) : (i += 1) {
                if (elements[i].key >= start_key and elements[i].key <= end_key) {
                    try rids.append(allocator, elements[i].value);
                } else if (elements[i].key > end_key) {
                    stop = true;
                    break;
                }
            }
            
            const next_leaf = meta.next_leaf;
            
            if (stop or next_leaf == 0) {
                current_frame.latch.unlockShared(io);
                self.buffer_manager.unpin_frame(current_frame, false);
                break;
            }
            
            const next_frame = try self.buffer_manager.fetch_frame(next_leaf);
            next_frame.latch.lockSharedUncancelable(io);
            
            current_frame.latch.unlockShared(io);
            self.buffer_manager.unpin_frame(current_frame, false);
            
            current_frame = next_frame;
        }
        
        return rids.toOwnedSlice(allocator);
    }

    fn log_page_meta(self: *BTree, txn_ctx: ?*TransactionContext, page_id: u32, frame: *Frame) !void {
        if (self.buffer_manager.log_manager) |lm| {
            if (txn_ctx) |ctx| {
                const lsn = try lm.append_record(ctx.txn_id, ctx.prev_lsn, .update_page_meta, page_id, 0, &[_]u8{});
                frame.page.header.lsn = lsn;
                ctx.prev_lsn = lsn;
            }
        }
    }

    /// Inserts a key-value pair into the B+Tree, handling root splits
    pub fn insert(self: *BTree, txn_ctx: ?*TransactionContext, key: u64, value: u64) !void {
        const io = self.buffer_manager.storage_manager.io;
        
        // Optimistically lock shared
        self.tree_latch.lockSharedUncancelable(io);
        var root_frame = try self.buffer_manager.fetch_frame(self.root_page_id);
        root_frame.latch.lockUncancelable(io);
        
        var view = BTreeNodeView{ .raw = &root_frame.page };
        var hold_tree_latch = false;
        
        if (!view.is_safe_for_insert()) {
            // Need exclusive tree latch because root might split
            root_frame.latch.unlock(io);
            self.buffer_manager.unpin_frame(root_frame, false);
            self.tree_latch.unlockShared(io);
            
            self.tree_latch.lockUncancelable(io);
            root_frame = try self.buffer_manager.fetch_frame(self.root_page_id);
            root_frame.latch.lockUncancelable(io);
            hold_tree_latch = true;
        } else {
            // Root is safe, tree won't change
            self.tree_latch.unlockShared(io);
        }

        const LockedAncestors = struct {
            items: [16]*Frame = undefined,
            len: usize = 0,
            pub fn append(s: *@This(), v: *Frame) void { s.items[s.len] = v; s.len += 1; }
            pub fn pop(s: *@This()) *Frame { s.len -= 1; return s.items[s.len]; }
            pub fn get(s: *@This(), idx: usize) *Frame { return s.items[idx]; }
            pub fn clear(s: *@This()) void { s.len = 0; }
            pub fn constSlice(s: *const @This()) []const *Frame { return s.items[0..s.len]; }
        };
        
        var locked_ancestors = LockedAncestors{};
        
        const split = try self.insert_recursive(txn_ctx, root_frame, key, value, &locked_ancestors);
        
        if (split) |s| {
            // Root split! We must have hold_tree_latch = true
            const new_root_id = try self.allocate_page();
            const new_root_frame = try self.buffer_manager.new_frame(new_root_id);
            new_root_frame.latch.lockUncancelable(io);

            var root_view = BTreeNodeView.init(&new_root_frame.page, .internal);
            
            root_view.set_leftmost_child(self.root_page_id);
            try root_view.internal_insert(s.key, s.right_child);
            
            try self.log_page_meta(txn_ctx, new_root_id, new_root_frame);

            new_root_frame.latch.unlock(io);
            self.buffer_manager.unpin_frame(new_root_frame, true);

            self.root_page_id = new_root_id;
        }
        
        if (hold_tree_latch) {
            self.tree_latch.unlock(io);
        }
    }

    const DeleteResult = union(enum) {
        none: void,
        node_empty: u32,
    };

    pub fn delete(self: *BTree, txn_ctx: ?*TransactionContext, key: u64) !void {
        const io = self.buffer_manager.storage_manager.io;
        
        self.tree_latch.lockSharedUncancelable(io);
        var root_frame = try self.buffer_manager.fetch_frame(self.root_page_id);
        root_frame.latch.lockUncancelable(io);
        
        var view = BTreeNodeView{ .raw = &root_frame.page };
        var hold_tree_latch = false;
        
        if (!view.is_safe_for_delete()) {
            root_frame.latch.unlock(io);
            self.buffer_manager.unpin_frame(root_frame, false);
            self.tree_latch.unlockShared(io);
            
            self.tree_latch.lockUncancelable(io);
            root_frame = try self.buffer_manager.fetch_frame(self.root_page_id);
            root_frame.latch.lockUncancelable(io);
            hold_tree_latch = true;
        } else {
            self.tree_latch.unlockShared(io);
        }

        const LockedAncestors = struct {
            items: [16]*Frame = undefined,
            len: usize = 0,
            pub fn append(s: *@This(), v: *Frame) void { s.items[s.len] = v; s.len += 1; }
            pub fn pop(s: *@This()) *Frame { s.len -= 1; return s.items[s.len]; }
            pub fn get(s: *@This(), idx: usize) *Frame { return s.items[idx]; }
            pub fn clear(s: *@This()) void { s.len = 0; }
            pub fn constSlice(s: *const @This()) []const *Frame { return s.items[0..s.len]; }
        };
        
        var locked_ancestors = LockedAncestors{};
        
        const res = try self.delete_recursive(txn_ctx, root_frame, key, &locked_ancestors);
        
        if (res == .node_empty) {
            // Root became empty. If it's internal, its only child becomes the new root.
            var root_view = BTreeNodeView{ .raw = &root_frame.page };
            const meta = root_view.get_meta();
            if (meta.node_type == .internal) {
                const new_root_id = root_view.get_leftmost_child();
                self.root_page_id = new_root_id;
            }
        }
        
        if (hold_tree_latch) {
            self.tree_latch.unlock(io);
        }
    }

    fn delete_recursive(self: *BTree, txn_ctx: ?*TransactionContext, current_frame: *Frame, key: u64, locked_ancestors: anytype) !DeleteResult {
        const io = self.buffer_manager.storage_manager.io;
        var view = BTreeNodeView{ .raw = &current_frame.page };
        
        if (view.is_safe_for_delete()) {
            for (locked_ancestors.constSlice()) |p_frame| {
                p_frame.latch.unlock(io);
                self.buffer_manager.unpin_frame(p_frame, false);
            }
            locked_ancestors.clear();
        }
        
        locked_ancestors.append(current_frame);
        
        const meta = view.get_meta();
        if (meta.node_type == .leaf) {
            view.leaf_delete(key) catch |err| {
                _ = locked_ancestors.pop();
                current_frame.latch.unlock(io);
                self.buffer_manager.unpin_frame(current_frame, false);
                return err;
            };
            
            try self.log_page_meta(txn_ctx, current_frame.page_id.?, current_frame);
            
            const new_meta = view.get_meta();
            if (new_meta.num_keys == 0 and locked_ancestors.len > 1) {
                current_frame.latch.unlock(io);
                self.buffer_manager.unpin_frame(current_frame, true);
                _ = locked_ancestors.pop();
                return DeleteResult{ .node_empty = current_frame.page_id.? };
            }
            
            _ = locked_ancestors.pop();
            current_frame.latch.unlock(io);
            self.buffer_manager.unpin_frame(current_frame, true);
            return .none;
        } else {
            const next_child_id = view.internal_search(key);
            
            const next_frame = try self.buffer_manager.fetch_frame(next_child_id);
            next_frame.latch.lockUncancelable(io);
            
            const child_res = try self.delete_recursive(txn_ctx, next_frame, key, locked_ancestors);
            
            switch (child_res) {
                .none => {
                    if (locked_ancestors.len > 0 and locked_ancestors.get(locked_ancestors.len - 1) == current_frame) {
                        _ = locked_ancestors.pop();
                        current_frame.latch.unlock(io);
                        self.buffer_manager.unpin_frame(current_frame, false); 
                    }
                    return .none;
                },
                .node_empty => |empty_child_id| {
                    try view.internal_delete(empty_child_id);
                    try self.log_page_meta(txn_ctx, current_frame.page_id.?, current_frame);
                    
                    const new_meta = view.get_meta();
                    if (new_meta.num_keys == 0 and locked_ancestors.len > 1) {
                        current_frame.latch.unlock(io);
                        self.buffer_manager.unpin_frame(current_frame, true);
                        _ = locked_ancestors.pop();
                        return DeleteResult{ .node_empty = current_frame.page_id.? };
                    }
                    
                    _ = locked_ancestors.pop();
                    current_frame.latch.unlock(io);
                    self.buffer_manager.unpin_frame(current_frame, true);
                    return .none;
                }
            }
        }
    }

    /// Recursively traverses down to the leaf, inserts, and bubbles splits back up using crabbing
    fn insert_recursive(self: *BTree, txn_ctx: ?*TransactionContext, current_frame: *Frame, key: u64, value: u64, locked_ancestors: anytype) !?SplitResult {
        const io = self.buffer_manager.storage_manager.io;
        var view = BTreeNodeView{ .raw = &current_frame.page };
        
        if (view.is_safe_for_insert()) {
            for (locked_ancestors.constSlice()) |p_frame| {
                p_frame.latch.unlock(io);
                self.buffer_manager.unpin_frame(p_frame, false); // Safe parents are NOT modified
            }
            locked_ancestors.clear();
        }
        
        locked_ancestors.append(current_frame);
        
        const meta = view.get_meta();
        if (meta.node_type == .leaf) {
            view.leaf_insert(key, value) catch |err| {
                if (err == error.NodeFull) {
                    const new_leaf_id = try self.allocate_page();
                    const new_leaf_frame = try self.buffer_manager.new_frame(new_leaf_id);
                    new_leaf_frame.latch.lockUncancelable(io);

                    var new_leaf_view = BTreeNodeView.init(&new_leaf_frame.page, .leaf);
                    view.split_leaf(&new_leaf_view, new_leaf_id);

                    const mid_key = new_leaf_view.get_leaf_elements()[0].key;
                    if (key >= mid_key) {
                        try new_leaf_view.leaf_insert(key, value);
                    } else {
                        try view.leaf_insert(key, value);
                    }
                    
                    try self.log_page_meta(txn_ctx, new_leaf_id, new_leaf_frame);
                    new_leaf_frame.latch.unlock(io);
                    self.buffer_manager.unpin_frame(new_leaf_frame, true);

                    _ = locked_ancestors.pop(); // pop current_frame
                    try self.log_page_meta(txn_ctx, current_frame.page_id.?, current_frame);
                    current_frame.latch.unlock(io);
                    self.buffer_manager.unpin_frame(current_frame, true);
                    
                    return SplitResult{ .key = mid_key, .right_child = new_leaf_id };
                }
                
                _ = locked_ancestors.pop();
                current_frame.latch.unlock(io);
                self.buffer_manager.unpin_frame(current_frame, false);
                return err;
            };
            
            _ = locked_ancestors.pop();
            try self.log_page_meta(txn_ctx, current_frame.page_id.?, current_frame);
            current_frame.latch.unlock(io);
            self.buffer_manager.unpin_frame(current_frame, true);
            return null;
        } else {
            const next_child_id = view.internal_search(key);
            
            // We fetch and lock the child before recursing!
            const next_frame = try self.buffer_manager.fetch_frame(next_child_id);
            next_frame.latch.lockUncancelable(io);
            
            const split_opt = try self.insert_recursive(txn_ctx, next_frame, key, value, locked_ancestors);
            
            if (split_opt) |s| {
                // If child split, we MUST STILL BE LOCKED.
                view.internal_insert(s.key, s.right_child) catch |err| {
                    if (err == error.NodeFull) {
                        const new_internal_id = try self.allocate_page();
                        const new_internal_frame = try self.buffer_manager.new_frame(new_internal_id);
                        new_internal_frame.latch.lockUncancelable(io);

                        var new_internal_view = BTreeNodeView.init(&new_internal_frame.page, .internal);
                        const push_up_key = view.split_internal(&new_internal_view);

                        if (s.key >= push_up_key) {
                            try new_internal_view.internal_insert(s.key, s.right_child);
                        } else {
                            try view.internal_insert(s.key, s.right_child);
                        }

                        try self.log_page_meta(txn_ctx, new_internal_id, new_internal_frame);
                        new_internal_frame.latch.unlock(io);
                        self.buffer_manager.unpin_frame(new_internal_frame, true);

                        _ = locked_ancestors.pop();
                        try self.log_page_meta(txn_ctx, current_frame.page_id.?, current_frame);
                        current_frame.latch.unlock(io);
                        self.buffer_manager.unpin_frame(current_frame, true);
                        return SplitResult{ .key = push_up_key, .right_child = new_internal_id };
                    }
                    _ = locked_ancestors.pop();
                    current_frame.latch.unlock(io);
                    self.buffer_manager.unpin_frame(current_frame, true);
                    return err;
                };
                
                _ = locked_ancestors.pop();
                try self.log_page_meta(txn_ctx, current_frame.page_id.?, current_frame);
                current_frame.latch.unlock(io);
                self.buffer_manager.unpin_frame(current_frame, true);
                return null;
            }
            
            // If child didn't split, and we are still in locked_ancestors, we unlock ourselves.
            if (locked_ancestors.len > 0 and locked_ancestors.get(locked_ancestors.len - 1) == current_frame) {
                _ = locked_ancestors.pop();
                current_frame.latch.unlock(io);
                self.buffer_manager.unpin_frame(current_frame, false); 
            }
            
            return null;
        }
    }
};
