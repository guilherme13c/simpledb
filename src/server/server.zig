const std = @import("std");
const Catalog = @import("../storage/catalog.zig").Catalog;
const connection = @import("connection.zig");
const LockManager = @import("../storage/concurrency/lock_manager.zig").LockManager;

/// Represents the main database server instance.
pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    catalog: *Catalog,
    active_txn_rwlock: std.Io.RwLock,
    active_transactions: std.AutoHashMap(u32, void),
    active_txn_mutex: std.Io.Mutex,
    next_txn_id: std.atomic.Value(u32),
    lock_manager: LockManager,

    /// Initializes a new Server instance.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16, catalog: *Catalog) !Server {
        return Server{
            .allocator = allocator,
            .io = io,
            .port = port,
            .catalog = catalog,
            .active_txn_rwlock = .init,
            .active_transactions = std.AutoHashMap(u32, void).init(allocator),
            .active_txn_mutex = .init,
            .next_txn_id = std.atomic.Value(u32).init(1),
            .lock_manager = LockManager.init(allocator, io),
        };
    }

    /// Starts a new transaction, recording it and capturing a snapshot.
    pub fn start_txn(self: *Server) @import("../storage/wal/transaction.zig").TransactionContext {
        self.active_txn_mutex.lockUncancelable(self.io);
        defer self.active_txn_mutex.unlock(self.io);
        const txn_id = self.next_txn_id.fetchAdd(1, .monotonic);
        const snap = self.active_transactions.clone() catch unreachable;
        self.active_transactions.put(txn_id, {}) catch unreachable;
        return .{
            .txn_id = txn_id,
            .lock_manager = &self.lock_manager,
            .active_snapshot = snap,
        };
    }

    /// Ends a transaction, cleaning up its tracking.
    pub fn end_txn(self: *Server, txn_ctx: *@import("../storage/wal/transaction.zig").TransactionContext) void {
        self.active_txn_mutex.lockUncancelable(self.io);
        defer self.active_txn_mutex.unlock(self.io);
        _ = self.active_transactions.remove(txn_ctx.txn_id);
        txn_ctx.deinit();
    }

    /// Starts the server and listens for incoming connections.
    pub fn start(self: *Server) !void {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
        var listener = try address.listen(self.io, .{ .reuse_address = true });
        defer listener.socket.close(self.io);

        std.debug.print("Server listening on 127.0.0.1:{d}\n", .{self.port});

        while (true) {
            var stream = listener.accept(self.io) catch |err| {
                std.debug.print("Error accepting connection: {}\n", .{err});
                continue;
            };
            std.debug.print("Accepted connection! (Spawning thread...)\n", .{});

            const thread = std.Thread.spawn(.{}, connection.handleConnection, .{ self, stream }) catch |err| {
                std.debug.print("Failed to spawn thread: {}\n", .{err});
                stream.close(self.io);
                continue;
            };
            thread.detach();
        }
    }

    /// Executes a statement directly (used by tests).
    pub fn execute_statement(self: *Server, stmt: @import("../query/ast.zig").Statement, txn_ctx: ?*@import("../storage/wal/transaction.zig").TransactionContext, writer: anytype, undo_stack: ?*std.ArrayList(@import("undo.zig").UndoOp)) !void {
        try @import("execution.zig").execute_statement(self.allocator, self.catalog, stmt, txn_ctx, writer, undo_stack);
    }
};
