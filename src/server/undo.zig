const builtin = @import("builtin");
const std = @import("std");
const Catalog = @import("../storage/catalog.zig").Catalog;

/// Represents an operation that can be undone in a transaction.
pub const UndoOp = union(enum) {
    delete_key: struct { table_name: []const u8, key: u64 },
    insert_key: struct { table_name: []const u8, key: u64, value: []const u8 },
};

/// Clears the undo stack and frees associated memory.
pub fn clear_undo_stack(undo_stack: *std.ArrayList(UndoOp), allocator: std.mem.Allocator) void {
    for (undo_stack.items) |op| {
        switch (op) {
            .delete_key => |d| allocator.free(d.table_name),
            .insert_key => |i| {
                allocator.free(i.table_name);
                allocator.free(i.value);
            },
        }
    }
    undo_stack.clearRetainingCapacity();
}

/// Executes all undo operations in reverse order, reverting changes.
pub fn execute_undo_stack(undo_stack: *std.ArrayList(UndoOp), catalog: *Catalog) void {
    if (!builtin.is_test) std.debug.print("Executing undo stack of size {}\n", .{undo_stack.items.len});
    var i: usize = undo_stack.items.len;
    while (i > 0) {
        i -= 1;
        const op = undo_stack.items[i];
        switch (op) {
            .delete_key => |d| {
                if (!builtin.is_test) std.debug.print("Undo delete key: {}\n", .{d.key});
                if (catalog.get_table(d.table_name)) |table| {
                    table.delete(null, d.key) catch |err| {
                        if (!builtin.is_test) std.debug.print("Undo delete error: {}\n", .{err});
                    };
                } else {
                    if (!builtin.is_test) std.debug.print("Table not found: {s}\n", .{d.table_name});
                }
            },
            .insert_key => |ins| {
                if (!builtin.is_test) std.debug.print("Undo insert key: {}\n", .{ins.key});
                if (catalog.get_table(ins.table_name)) |table| {
                    _ = table.insert(null, ins.key, ins.value) catch |err| {
                        if (!builtin.is_test) std.debug.print("Undo insert error: {}\n", .{err});
                    };
                }
            },
        }
    }
}
