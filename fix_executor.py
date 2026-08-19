import re

with open("src/query/executor.zig", "r") as f:
    content = f.read()

content = content.replace('pub const LimitExecutor = @import("executor/limit.zig").LimitExecutor;', 'pub const LimitExecutor = @import("executor/limit.zig").LimitExecutor;\npub const InMemoryScanExecutor = @import("executor/in_memory_scan.zig").InMemoryScanExecutor;\npub const InMemoryInsertExecutor = @import("executor/in_memory_insert.zig").InMemoryInsertExecutor;')

content = content.replace('limit: *LimitExecutor,', 'limit: *LimitExecutor,\n    in_memory_scan: *InMemoryScanExecutor,\n    in_memory_insert: *InMemoryInsertExecutor,')

content = content.replace('.limit => |e| try e.open(),', '.limit => |e| try e.open(),\n            .in_memory_scan => |e| try e.open(),\n            .in_memory_insert => |e| try e.open(),')

content = content.replace('.limit => |e| e.next(),', '.limit => |e| e.next(),\n            .in_memory_scan => |e| e.next(),\n            .in_memory_insert => |e| e.next(),')

content = content.replace('.limit => |e| e.close(),', '.limit => |e| e.close(),\n            .in_memory_scan => |e| e.close(),\n            .in_memory_insert => |e| e.close(),')

content = content.replace('.limit => |e| { e.child.destroy(allocator); allocator.destroy(e); },', '.limit => |e| { e.child.destroy(allocator); allocator.destroy(e); },\n            .in_memory_scan => |e| allocator.destroy(e),\n            .in_memory_insert => |e| { e.child.destroy(allocator); allocator.destroy(e); },')

content = content.replace('.limit => try writer.print("{s}-> Limit\n", .{indent_buf[0..depth * 2]}),', '.limit => try writer.print("{s}-> Limit\n", .{indent_buf[0..depth * 2]}),\n            .in_memory_scan => try writer.print("{s}-> InMemoryScan\n", .{indent_buf[0..depth * 2]}),\n            .in_memory_insert => try writer.print("{s}-> InMemoryInsert\n", .{indent_buf[0..depth * 2]}),')

with open("src/query/executor.zig", "w") as f:
    f.write(content)
