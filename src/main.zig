const std = @import("std");

const CHARS = "  .:!+*e$@8";
const ASCII_WIDTH = 100;
const ASCII_HEIGHT = 40;
const FPS = 15;
const FRAME_DURATION_MS = 1000 / FPS;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const temp_dir = "temp_frames";
    std.fs.cwd().makeDir(temp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree(temp_dir) catch {
        std.debug.print("Failed to delete temporary frames directory.\n", .{});
    };

    std.debug.print("Extracting frames from video...\n", .{});
    try extractFrames(allocator, "/home/gihyun/Development/video-to-ascii/videos/bad-apple.mp4", temp_dir);

    var frame_files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (frame_files.items) |file| {
            allocator.free(file);
        }
        frame_files.deinit();
    }

    std.debug.print("Getting frame files...\n", .{});
    try getFrameFiles(allocator, temp_dir, &frame_files);
    std.debug.print("Found {d} frames.\n", .{frame_files.items.len});

    std.debug.print("Preloading ASCII frames...\n", .{});
    const frames = try preloadAsciiFrames(allocator, frame_files.items);
    std.debug.print("Success.\n", .{});

    std.debug.print("Extracting audio...\n", .{});
    try extractAudio(allocator);
    std.debug.print("Success.\n", .{});

    // ???
    std.debug.print("\x1b[2J\x1b[?25l\x1b[?1049h", .{});
    defer {
        std.debug.print("\x1b[?1049l\x1b[?25h", .{});
        std.debug.print("Playback finished.\n", .{});
    }

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    std.debug.print("Starting playback...\n", .{});
    std.time.sleep(1 * std.time.ns_per_s);

    var audio_process = try playAudio(allocator);
    defer {
        _ = audio_process.kill() catch {
            std.debug.print("Failed to kill audio process.\n", .{});
        };
        std.fs.cwd().deleteFile("output.m4a") catch {};
    }

    for (frames) |frame| {
        try stdout.print("\x1b[H{s}", .{frame});
        try bw.flush();
        std.time.sleep(FRAME_DURATION_MS * std.time.ns_per_ms);
    }
}

// A function iniitally used for image to ASCII
// fn asciiToImage(allocator: std.mem.Allocator) !void {
//     const convert_cmd = [_][]const u8{ "magick", "/home/gihyun/Development/video-to-ascii/images/mika-xD.jpg", "bmp:-" };
//
//     var child = std.process.Child.init(&convert_cmd, allocator);
//     child.stdout_behavior = .Pipe;
//     child.stderr_behavior = .Pipe;
//
//     try child.spawn();
//
//     const stdout = try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
//     defer allocator.free(stdout);
//
//     const term = try child.wait();
//     if (term.Exited != 0) {
//         std.debug.print("Error\n", .{});
//         return;
//     }
//
//     try bmpToAscii(stdout, ASCII_WIDTH, ASCII_HEIGHT);
// }

fn bmpToAscii(allocator: std.mem.Allocator, data: []const u8, ascii_width: u32, ascii_height: u32) ![]const u8 {
    const width = std.mem.readInt(u32, data[18..22], .little);
    const height = std.mem.readInt(u32, data[22..26], .little);
    const data_offset = std.mem.readInt(u32, data[10..14], .little);

    const pixel_data = data[data_offset..];
    const x_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(ascii_width));
    const y_ratio = @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(ascii_height));

    var chars = std.ArrayList(u8).init(allocator);
    defer chars.deinit();

    var y: u32 = 0;
    while (y < ascii_height) : (y += 1) {
        var x: u32 = 0;
        while (x < ascii_width) : (x += 1) {
            const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(x)) * x_ratio));
            const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(y)) * y_ratio));

            // BMP is stored bottom-to-top, so flip Y coordinate
            const flipped_y = height - 1 - src_y;

            const pixel_idx = (flipped_y * width + src_x) * 3;
            if (pixel_idx + 2 < pixel_data.len) {
                const b = pixel_data[pixel_idx];
                const g = pixel_data[pixel_idx + 1];
                const r = pixel_data[pixel_idx + 2];

                const ascii_char = pixelToAscii(r, g, b);
                try chars.append(ascii_char);
            } else {
                try chars.append(' ');
            }
        }

        try chars.append('\n');
    }

    const str = try chars.toOwnedSlice();
    return str;
}

fn pixelToAscii(r: u8, g: u8, b: u8) u8 {
    const gray = (@as(u32, @intCast(r)) * 299 + @as(u32, @intCast(g)) * 587 + @as(u32, @intCast(b)) * 114) / 1000;
    const index = @min(gray * (CHARS.len - 1) / 255, CHARS.len - 1);
    return CHARS[index];
}

fn extractFrames(allocator: std.mem.Allocator, file_dir: []const u8, output_dir: []const u8) !void {
    const frame_name = try std.fmt.allocPrint(allocator, "{s}/frame_%04d.bmp", .{output_dir});
    defer allocator.free(frame_name);
    const extract_cmd = [_][]const u8{ "ffmpeg", "-i", file_dir, "-vf", "fps=15", "-y", frame_name };

    var child = std.process.Child.init(&extract_cmd, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    if (term.Exited != 0) {
        std.debug.print("Failed to extract frames.\n", .{});
        return;
    }
}

fn getFrameFiles(allocator: std.mem.Allocator, dir_path: []const u8, frame_files: *std.ArrayList([]const u8)) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".bmp")) {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            try frame_files.append(full_path);
        }
    }

    std.mem.sort([]const u8, frame_files.items, {}, compareStrings);
}

fn compareStrings(context: void, a: []const u8, b: []const u8) bool {
    _ = context;
    return std.mem.lessThan(u8, a, b);
}

fn extractAudio(allocator: std.mem.Allocator) !void {
    const cmd = [_][]const u8{ "ffmpeg", "-i", "/home/gihyun/Development/video-to-ascii/videos/bad-apple.mp4", "-vn", "-acodec", "copy", "-y", "output.m4a" };

    var child = std.process.Child.init(&cmd, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    if (term.Exited != 0) {
        std.debug.print("Failed to extract audio.\n", .{});
        return;
    }
}

fn playAudio(allocator: std.mem.Allocator) !std.process.Child {
    const cmd = [_][]const u8{ "cvlc", "output.m4a" };

    var child = std.process.Child.init(&cmd, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    return child;
}

fn preloadAsciiFrames(allocator: std.mem.Allocator, frame_files: [][]const u8) ![][]const u8 {
    var frames = try std.ArrayList([]const u8).initCapacity(allocator, frame_files.len);
    defer frames.deinit();

    for (frame_files) |path| {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const data = try allocator.alloc(u8, file_size);
        defer allocator.free(data);

        _ = try file.readAll(data);

        const ascii_frame = try bmpToAscii(allocator, data, ASCII_WIDTH, ASCII_HEIGHT);
        try frames.append(ascii_frame);
    }

    return frames.toOwnedSlice();
}
