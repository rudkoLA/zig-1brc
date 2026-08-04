const std = @import("std");

const Station = struct {
    min: i16 = 0,
    sum: i32 = 0,
    max: i16 = 0,
    len: usize = 0,
};

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn fastParseFloat(slice: []u8) i16 {
    var number: i16 = 0;

    for (slice) |byte| {
        if ('0' <= byte and byte <= '9') {
            number *= 10;
            number += (byte - '0');
        }
    }

    return if (slice[0] == '-') -number else number;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 3) {
        return error.WrongArgumentCount;
    }

    const cwd = std.Io.Dir.cwd();

    const input_file = args[1];
    const output_file = args[2];

    const file = try cwd.openFile(io, input_file, .{});
    defer file.close(io);

    var read_buf: [1 << 12]u8 = undefined;

    var file_reader = file.reader(io, &read_buf);
    var reader = &file_reader.interface;

    const buffer_size = 1 << 17;
    var buffer: [buffer_size]u8 = undefined;

    var read_start: usize = 0;

    var hash_map: std.StringHashMap(Station) = .init(gpa);
    defer hash_map.deinit();

    const start = std.Io.Timestamp.now(io, .real);

    while (true) {
        const read_bytes = try reader.readSliceShort(buffer[read_start..]);

        if (read_bytes == 0) break;

        var i: usize = 0;

        const total_len = read_start + read_bytes;

        while (i < total_len) {
            const next_semicolon = std.mem.findScalarPos(u8, &buffer, i, ';') orelse break;

            const key = buffer[i..next_semicolon];

            const next_new_line = std.mem.findScalarPos(u8, &buffer, next_semicolon, '\n') orelse break;

            const value: i16 = fastParseFloat(buffer[next_semicolon + 1 .. next_new_line]);

            const station = try hash_map.getOrPut(key);

            if (station.found_existing) {
                station.value_ptr.sum += value;
                station.value_ptr.len += 1;

                station.value_ptr.max = @max(station.value_ptr.max, value);
                station.value_ptr.min = @min(station.value_ptr.min, value);
            } else {
                station.key_ptr.* = try arena.dupe(u8, key);

                station.value_ptr.* = .{
                    .max = value,
                    .min = value,
                    .sum = value,
                    .len = 1,
                };
            }
            i = next_new_line + 1;
        }

        if (i < total_len) {
            read_start = total_len - i;
            @memcpy(buffer[0..read_start], buffer[i..total_len]);
        } else {
            read_start = 0;
        }
    }
    const reading = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();

    std.debug.print("Finished reading and parsing at {}\n", .{reading});

    var output_string_arr: std.ArrayList([]u8) = .empty;
    defer output_string_arr.deinit(gpa);

    var iter = hash_map.keyIterator();

    try output_string_arr.ensureUnusedCapacity(gpa, hash_map.count());

    while (iter.next()) |station_name| {
        const mutable_station_name = @constCast(station_name.*);

        output_string_arr.appendAssumeCapacity(mutable_station_name);
    }

    std.mem.sort([]u8, output_string_arr.items, {}, stringLessThan);

    var write_buf: [1 << 12]u8 = undefined;

    const output_file_creator = try cwd.createFile(io, output_file, .{});
    defer output_file_creator.close(io);

    var output_file_writer = output_file_creator.writer(io, &write_buf);
    var writer = &output_file_writer.interface;

    for (output_string_arr.items) |value| {
        const station = hash_map.get(value) orelse unreachable;

        const min = @as(f64, @floatFromInt(station.min));
        const max = @as(f64, @floatFromInt(station.max));

        const avg = @as(f64, @floatFromInt(station.sum)) / @as(f64, @floatFromInt(station.len));

        try writer.print("{s}={d}/{d}/{d}\n", .{ value, min / 10, avg / 10, max / 10 });
    }
    const writing = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();

    std.debug.print("Finished writing at {}\n", .{writing});

    try writer.flush();
}
