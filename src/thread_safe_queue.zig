const std = @import("std");

pub fn ThreadSafeQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        queue: std.Deque(T),
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .queue = try std.Deque(T).initCapacity(allocator, 16),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.queue.deinit(allocator);
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, io: std.Io, item: T) !void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            if (self.closed) return error.ClosedQueue;

            try self.queue.pushBack(allocator, item);
            self.condition.signal(io);
        }

        pub fn get(self: *Self, io: std.Io) !?T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            while (self.queue.len == 0 and !self.closed) {
                try self.condition.wait(io, &self.mutex);
            }

            if (self.queue.len == 0) return null;

            if (self.queue.popFront()) |item| {
                return item;
            }

            return null;
        }

        pub fn close(self: *Self, io: std.Io) !void {
            self.closed = true;
            self.condition.broadcast(io);
        }
    };
}
