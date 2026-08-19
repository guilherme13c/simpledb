const std = @import("std");
const ast = @import("../query/ast.zig");
const dupe_value = @import("../query/executor.zig").dupe_value;
const free_tuple = @import("../query/executor.zig").free_tuple;

pub const InMemoryTable = struct {
    allocator: std.mem.Allocator,
    schema: []const ast.ColumnDef,
    tuples: std.ArrayListUnmanaged([]ast.Value),

    pub fn init(allocator: std.mem.Allocator, schema: []const ast.ColumnDef) !InMemoryTable {
        const schema_dupe = try allocator.alloc(ast.ColumnDef, schema.len);
        for (schema, 0..) |col, i| {
            schema_dupe[i] = .{
                .name = try allocator.dupe(u8, col.name),
                .data_type = col.data_type,
                
            };
        }
        return .{
            .allocator = allocator,
            .schema = schema_dupe,
            .tuples = std.ArrayListUnmanaged([]ast.Value).empty,
        };
    }

    pub fn deinit(self: *InMemoryTable) void {
        for (self.schema) |col| {
            self.allocator.free(col.name);
        }
        self.allocator.free(self.schema);
        for (self.tuples.items) |tuple| {
            free_tuple(self.allocator, tuple);
        }
        self.tuples.deinit(self.allocator);
    }

    pub fn insert_tuple(self: *InMemoryTable, tuple: []const ast.Value) !void {
        var duped = try self.allocator.alloc(ast.Value, tuple.len);
        for (tuple, 0..) |v, i| {
            duped[i] = try dupe_value(self.allocator, v);
        }
        try self.tuples.append(self.allocator, duped);
    }
};
