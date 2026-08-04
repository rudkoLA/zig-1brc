const std = @import("std");
const tsqueue = @import("thread_safe_queue.zig");

const Station = struct {
    min: i16 = 0,
    sum: i32 = 0,
    max: i16 = 0,
    len: usize = 0,
};

const StationMap = std.StringHashMap(Station);
const BufferQueue = tsqueue.ThreadSafeQueue([]u8);

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn fastParseFloat(slice: []u8) i16 {
    var number: i16 = 0;

    for (slice) |byte| {
        if ('0' <= byte and byte <= '9') {
            number = number * 10 + (byte - '0');
        }
    }

    return if (slice[0] == '-') -number else number;
}

fn parseBuffer(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, bufferQueue: *BufferQueue, station_map: *StationMap) !void {
    while (try bufferQueue.get(io)) |buffer| {
        defer gpa.free(buffer);

        var i: usize = 0;

        while (i < buffer.len) {
            const next_semicolon = std.mem.findScalarPos(u8, buffer, i, ';') orelse break;

            const key = buffer[i..next_semicolon];

            const next_new_line = std.mem.findScalarPos(u8, buffer, next_semicolon, '\n') orelse break;

            if (next_semicolon == next_new_line) break;
            if (next_semicolon + 1 == next_new_line) break;

            const value: i16 = fastParseFloat(buffer[next_semicolon + 1 .. next_new_line]);

            const station = try station_map.getOrPut(key);

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
    }
}

const ParseResult = @typeInfo(@TypeOf(parseBuffer)).@"fn".return_type.?;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 4) {
        return error.WrongArgumentCount;
    }

    const cwd = std.Io.Dir.cwd();

    const input_file = args[1];
    const output_file = args[2];
    const thread_count = try std.fmt.parseInt(u8, args[3], 10);

    const file = try cwd.openFile(io, input_file, .{});
    defer file.close(io);

    var read_buf: [1 << 12]u8 = undefined;

    var file_reader = file.reader(io, &read_buf);
    var reader = &file_reader.interface;

    var bufferQueue: BufferQueue = try .init(gpa);
    defer bufferQueue.deinit(gpa);

    var thread_station_maps: std.ArrayList(*StationMap) = try .initCapacity(gpa, thread_count);
    defer thread_station_maps.deinit(gpa);

    var futures: std.ArrayList(std.Io.Future(ParseResult)) = try .initCapacity(gpa, thread_count);
    defer futures.deinit(gpa);

    for (0..thread_count) |_| {
        const thread_station_map = try arena.create(StationMap);
        thread_station_map.* = StationMap.init(arena);

        thread_station_maps.appendAssumeCapacity(thread_station_map);

        futures.appendAssumeCapacity(try io.concurrent(parseBuffer, .{ arena, gpa, io, &bufferQueue, thread_station_map }));
    }

    const buffer_size = 1 << 22;
    var buffer: [buffer_size]u8 = undefined;

    var read_start: usize = 0;

    const start = std.Io.Timestamp.now(io, .real);

    while (true) {
        const read_bytes = try reader.readSliceShort(buffer[read_start..]);
        const total_len = read_start + read_bytes;

        if (total_len == 0) break;

        var i: usize = 0;

        while (i < total_len) {
            const thread_buffer_start = i;

            const target_end = @min(total_len, i + (total_len / thread_count) + 1);

            var thread_buffer_end = std.mem.findScalarPos(u8, buffer[0..total_len], target_end, '\n') orelse total_len;

            if (read_bytes == 0) {
                thread_buffer_end = total_len;
            }

            const slice = buffer[thread_buffer_start..thread_buffer_end];
            if (slice.len > 0) {
                const chunk = try gpa.dupe(u8, slice);

                try bufferQueue.put(gpa, io, chunk);
            }

            i = if (thread_buffer_end < total_len) thread_buffer_end + 1 else total_len;
        }

        if (i < total_len) {
            read_start = total_len - i;
            @memcpy(buffer[0..read_start], buffer[i..total_len]);
        } else {
            read_start = 0;
        }

        if (read_bytes == 0) break;
    }

    const reading = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();

    std.debug.print("Finished reading at {}\n", .{reading});

    try bufferQueue.close(io);

    for (futures.items) |*future| {
        try future.await(io);
    }

    const parsing = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();

    std.debug.print("Finished parsing at {}\n", .{parsing});

    var main_station_map: StationMap = .init(gpa);
    defer main_station_map.deinit();

    for (thread_station_maps.items) |station_map| {
        var station_iter = station_map.iterator();

        while (station_iter.next()) |thread_station| {
            const thread_station_value = thread_station.value_ptr;
            const thread_station_key = thread_station.key_ptr.*;

            const main_station = try main_station_map.getOrPut(thread_station_key);
            const main_station_value = main_station.value_ptr;

            if (main_station.found_existing) {
                main_station_value.min = @min(main_station_value.min, thread_station_value.min);
                main_station_value.max = @max(main_station_value.max, thread_station_value.max);
                main_station_value.len = main_station_value.len + thread_station_value.len;
                main_station_value.sum = main_station_value.sum + thread_station_value.sum;
            } else {
                main_station.key_ptr.* = try arena.dupe(u8, thread_station_key);
                main_station.value_ptr.* = thread_station_value.*;
            }
        }
    }

    const merging = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();

    std.debug.print("Finished merging at {}\n", .{merging});

    var iter = main_station_map.keyIterator();

    var output_string_arr: std.ArrayList([]u8) = .empty;
    defer output_string_arr.deinit(gpa);

    try output_string_arr.ensureUnusedCapacity(gpa, main_station_map.count());

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
        const station = main_station_map.get(value) orelse unreachable;

        const min = @as(f64, @floatFromInt(station.min));
        const max = @as(f64, @floatFromInt(station.max));

        const avg = @as(f64, @floatFromInt(station.sum)) / @as(f64, @floatFromInt(station.len));

        try writer.print("{s}={d}/{d}/{d}\n", .{ value, min / 10, avg / 10, max / 10 });
    }

    const writing = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();

    std.debug.print("Finished writing at {}\n", .{writing});

    try writer.flush();
}
