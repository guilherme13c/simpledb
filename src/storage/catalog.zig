const std = @import("std");
const Table = @import("table.zig").Table;
const BTree = @import("index/btree.zig").BTree;
const BufferManager = @import("buffer_manager/buffer_manager.zig").BufferManager;
const ast = @import("../query/ast.zig");

pub const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    buffer_manager: *BufferManager,
    next_page_counter: *u32,
    tables: std.StringHashMap(*Table),
    mutex: SpinLock,

    pub fn init(allocator: std.mem.Allocator, buffer_manager: *BufferManager, next_page_counter: *u32) !Catalog {
        var catalog = Catalog{
            .allocator = allocator,
            .buffer_manager = buffer_manager,
            .next_page_counter = next_page_counter,
            .tables = std.StringHashMap(*Table).init(allocator),
            .mutex = .{},
        };

        const file_size = try buffer_manager.storage_manager.get_file_size();

        if (file_size == 0) {
            // New database!
            next_page_counter.* = 0;
            
            // Allocate sys_tables root
            const sys_root = next_page_counter.*; // 0
            next_page_counter.* += 1;
            
            {
                const sys_frame = try buffer_manager.new_frame(sys_root);
                _ = @import("index/btree_node.zig").BTreeNodeView.init(&sys_frame.page, .leaf);
                buffer_manager.unpin_frame(sys_frame, true);
            }

            const sys_btree = try allocator.create(BTree);
            sys_btree.* = try BTree.init(buffer_manager, sys_root, next_page_counter);
            const sys_table = try allocator.create(Table);
            sys_table.* = try Table.init(allocator, buffer_manager, sys_btree, next_page_counter, &[_]ast.ColumnDef{});
            
            const name_dup = try allocator.dupe(u8, "sys_tables");
            try catalog.tables.put(name_dup, sys_table);
        } else {
            // Existing database!
            next_page_counter.* = @intCast(file_size / @import("page/page.zig").page_size);

            const sys_root = 0; // Hardcoded to 0

            const sys_btree = try allocator.create(BTree);
            sys_btree.* = try BTree.init(buffer_manager, sys_root, next_page_counter);
            const sys_table = try allocator.create(Table);
            sys_table.* = try Table.init(allocator, buffer_manager, sys_btree, next_page_counter, &[_]ast.ColumnDef{});
            
            const name_dup = try allocator.dupe(u8, "sys_tables");
            try catalog.tables.put(name_dup, sys_table);

            try catalog.load_sys_tables();
        }

        return catalog;
    }

    fn load_sys_tables(self: *Catalog) !void {
        const sys_table = self.tables.get("sys_tables").?;
        const all_entries = try sys_table.scan(self.allocator, null, 0, std.math.maxInt(u64));
        defer self.allocator.free(all_entries);

        for (all_entries) |entry| {
            if (entry.len < 4) {
                self.allocator.free(entry);
                continue;
            }
            
            const root_id = std.mem.readInt(u32, entry[0..4][0..4], .little);
            var offset: usize = 4;
            
            var schema_list = std.ArrayList(ast.ColumnDef).empty;
            defer schema_list.deinit(self.allocator);
            
            if (root_id != std.math.maxInt(u32)) {
                if (offset < entry.len) {
                    const num_columns = entry[offset];
                    offset += 1;
                    var i: usize = 0;
                    while (i < num_columns) : (i += 1) {
                        const dtype: ast.DataType = @enumFromInt(entry[offset]);
                        offset += 1;
                        const name_len = entry[offset];
                        offset += 1;
                        const col_name = entry[offset..offset+name_len];
                        offset += name_len;
                        const dup_name = try self.allocator.dupe(u8, col_name);
                        try schema_list.append(self.allocator, .{ .name = dup_name, .data_type = dtype });
                    }
                }
            }
            const table_name = entry[offset..];

            if (root_id == std.math.maxInt(u32)) {
                // Tombstone
                if (self.tables.fetchRemove(table_name)) |kv| {
                    self.free_table(kv.value);
                    self.allocator.free(kv.key);
                }
            } else {
                const btree = try self.allocator.create(BTree);
                btree.* = try BTree.init(self.buffer_manager, root_id, self.next_page_counter);

                const table = try self.allocator.create(Table);
                const final_schema = try schema_list.toOwnedSlice(self.allocator);
                table.* = try Table.init(self.allocator, self.buffer_manager, btree, self.next_page_counter, final_schema);

                const name_dup = try self.allocator.dupe(u8, table_name);
                
                // If it already exists, replace it and clean up the old one (handling updates if any)
                if (self.tables.fetchRemove(name_dup)) |kv| {
                    self.free_table(kv.value);
                    self.allocator.free(kv.key);
                }
                
                try self.tables.put(name_dup, table);
            }
            
            self.allocator.free(entry);
        }
    }

    fn free_table(self: *Catalog, table: *@import("table.zig").Table) void {
        for (table.schema) |col| self.allocator.free(col.name);
        self.allocator.free(table.schema);
        self.allocator.destroy(table.btree);
        
        var idx_it = table.indexes.iterator();
        while (idx_it.next()) |idx_kv| {
            self.allocator.free(idx_kv.key_ptr.*);
            self.allocator.destroy(idx_kv.value_ptr.*.btree);
        }
        table.indexes.deinit();
        self.allocator.destroy(table);
    }

    pub fn deinit(self: *Catalog) void {
        var it = self.tables.iterator();
        while (it.next()) |kv| {
            self.free_table(kv.value_ptr.*);
            self.allocator.free(kv.key_ptr.*);
        }
        self.tables.deinit();
    }

    pub fn create_table(self: *Catalog, name: []const u8, schema: []const ast.ColumnDef) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tables.contains(name)) {
            return error.TableAlreadyExists;
        }

        // Allocate a new root page for BTree
        const root_page_id = self.next_page_counter.*;
        self.next_page_counter.* += 1;
        
        {
            const root_frame = try self.buffer_manager.new_frame(root_page_id);
            _ = @import("index/btree_node.zig").BTreeNodeView.init(&root_frame.page, .leaf);
            self.buffer_manager.unpin_frame(root_frame, true);
        }

        const btree = try self.allocator.create(BTree);
        btree.* = try BTree.init(self.buffer_manager, root_page_id, self.next_page_counter);

        const table = try self.allocator.create(Table);
        
        var schema_dup = try self.allocator.alloc(ast.ColumnDef, schema.len);
        for (schema, 0..) |col, i| {
            schema_dup[i] = .{
                .name = try self.allocator.dupe(u8, col.name),
                .data_type = col.data_type,
            };
        }
        
        table.* = try Table.init(self.allocator, self.buffer_manager, btree, self.next_page_counter, schema_dup);

        const name_dup = try self.allocator.dupe(u8, name);
        try self.tables.put(name_dup, table);

        if (!std.mem.eql(u8, name, "sys_tables")) {
            const sys_table = self.tables.get("sys_tables").?;
            
            var buf: [1024]u8 = undefined;
            var offset: usize = 0;
            std.mem.writeInt(u32, buf[0..4], root_page_id, .little);
            offset += 4;
            buf[offset] = @intCast(schema.len);
            offset += 1;
            for (schema) |col| {
                buf[offset] = @intFromEnum(col.data_type);
                offset += 1;
                buf[offset] = @intCast(col.name.len);
                offset += 1;
                std.mem.copyForwards(u8, buf[offset..], col.name);
                offset += col.name.len;
            }
            std.mem.copyForwards(u8, buf[offset..], name);
            offset += name.len;
            const payload = buf[0 .. offset];
            
            const key = std.hash.Wyhash.hash(0, name);
            _ = try sys_table.insert(null, key, payload);
        }
    }

    pub fn create_index(self: *Catalog, index_name: []const u8, table_name: []const u8, column_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const table = self.tables.get(table_name) orelse return error.TableNotFound;
        
        var col_idx: ?usize = null;
        for (table.schema, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, column_name)) {
                col_idx = i;
                break;
            }
        }
        
        if (col_idx == null) return error.ColumnNotFound;
        if (table.indexes.contains(index_name)) return error.IndexAlreadyExists;

        const root_page_id = self.next_page_counter.*;
        self.next_page_counter.* += 1;
        
        {
            const root_frame = try self.buffer_manager.new_frame(root_page_id);
            _ = @import("index/btree_node.zig").BTreeNodeView.init(&root_frame.page, .leaf);
            self.buffer_manager.unpin_frame(root_frame, true);
        }

        const btree = try self.allocator.create(BTree);
        btree.* = try BTree.init(self.buffer_manager, root_page_id, self.next_page_counter);

        const index_def = @import("table.zig").IndexDef{
            .column_idx = col_idx.?,
            .btree = btree,
        };
        
        try table.indexes.put(try self.allocator.dupe(u8, index_name), index_def);

        // Populate index with existing data
        const rids = try table.btree.scan(self.allocator, 0, std.math.maxInt(u64));
        defer self.allocator.free(rids);

        for (rids) |rid| {
            const heap_page_id: u32 = @intCast(rid >> 32);
            const slot_id: u16 = @intCast(rid & 0xFFFF);

            const frame = try self.buffer_manager.fetch_frame(heap_page_id);
            var view = @import("page/slotted_view.zig").SlottedView.init(&frame.page, false);
            
            if (view.get_tuple(slot_id)) |data| {
                if (table.deserialize_tuple(self.allocator, data)) |tuple| {
                    defer @import("../query/executor.zig").free_tuple(self.allocator, tuple);
                    const val = tuple[col_idx.?];
                    const hash_key = switch (val) {
                        .int => |v| v,
                        .varchar => |s| std.hash.Wyhash.hash(0, s),
                        .bool => |b| @as(u64, if (b) 1 else 0),
                        .float => |f| @as(u64, @bitCast(f)),
                        .signed_int => |i| @as(u64, @bitCast(i)),
                        else => 0,
                    };
                    try btree.insert(null, hash_key, rid);
                } else |_| {}
            }
            self.buffer_manager.unpin_frame(frame, false);
        }
    }

    pub fn get_table(self: *Catalog, name: []const u8) ?*Table {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tables.get(name);
    }

    pub fn drop_table(self: *Catalog, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tables.fetchRemove(name)) |kv| {
            // We're just leaking the pages on disk for now since this is a toy DB.
            const table = kv.value;
            for (table.schema) |col| self.allocator.free(col.name);
            self.allocator.free(table.schema);
            self.allocator.destroy(table.btree);
            self.allocator.destroy(table);
            self.allocator.free(kv.key);

            if (!std.mem.eql(u8, name, "sys_tables")) {
                const sys_table = self.tables.get("sys_tables").?;
                
                var buf: [256]u8 = undefined;
                std.mem.writeInt(u32, buf[0..4], std.math.maxInt(u32), .little);
                std.mem.copyForwards(u8, buf[4..], name);
                const payload = buf[0 .. 4 + name.len];
                
                const key = std.hash.Wyhash.hash(0, name);
                _ = try sys_table.insert(null, key, payload);
            }
        } else {
            return error.TableNotFound;
        }
    }
};
