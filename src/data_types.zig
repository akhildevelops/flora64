const std = @import("std");
pub const OwnedString = struct {
    string: []const u8,
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.string);
    }
};

pub fn Vec(T: type) type {
    return struct {
        inner: []T,
        index: 0,
    };
}
pub fn Iterator(T: type) type {
    return struct {
        context: *anyopaque,
        _next: *const fn (*anyopaque) ?T,
        _deinit: *const fn (*anyopaque, allocaotr: std.mem.Allocator) void = struct {
            pub fn _de(_: *anyopaque, _: std.mem.Allocator) void {}
        }._de,
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self._deinit(self.context, allocator);
        }
        pub fn next(self: *@This()) ?T {
            return self._next(self.context);
        }
        pub fn mut(self: @This()) *@This() {
            return @constCast(&self);
        }
        pub fn map(self: *@This(), U: type, Context: type, context: Context, transform: *const fn (Context, T) U) Iterator(U) {
            return .{
                .context = self,
                ._next = struct {
                    pub fn _next(_context: *anyopaque) ?U {
                        const iterator: *Iterator(T) = @ptrCast(@alignCast(_context));
                        return if (iterator.next()) |value| transform(context, value) orelse null;
                    }
                },
                ._deinit = struct {
                    pub fn _de(_context: *anyopaque, allocator: std.mem.Allocator) void {
                        const iterator: *Iterator(T) = @ptrCast(@alignCast(_context));
                        iterator.deinit(allocator);
                    }
                }._de,
            };
        }
    };
}
