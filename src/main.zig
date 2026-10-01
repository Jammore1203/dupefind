const std = @import("std");
const dupes = @import("dupes.zig");

const usage =
    \\usage: dupefind [options] [DIR...]
    \\
    \\Find duplicate files under each DIR (default: current directory).
    \\
    \\  -m, --min-size N   ignore files smaller than N bytes (k/m/g suffixes ok)
    \\  -a, --all          include hidden files and directories (.git, .cache, ...)
    \\  -s, --summary      print only the totals
    \\  -0, --null         print duplicate paths NUL-separated, for xargs -0
    \\  -h, --help         show this help
    \\
;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const stderr = std.io.getStdErr().writer();
    var out_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const out = out_buf.writer();

    var opts = dupes.Options{};
    var summary_only = false;
    var null_mode = false;
    var roots = std.ArrayList([]const u8).init(gpa);
    defer roots.deinit();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-h") or eql(a, "--help")) {
            try out.writeAll(usage);
            return out_buf.flush();
        } else if (eql(a, "-m") or eql(a, "--min-size")) {
            i += 1;
            if (i >= args.len) return fail(stderr, "{s} needs a value", .{a});
            opts.min_size = parseSize(args[i]) orelse
                return fail(stderr, "bad size '{s}'", .{args[i]});
        } else if (eql(a, "-a") or eql(a, "--all")) {
            opts.include_hidden = true;
        } else if (eql(a, "-s") or eql(a, "--summary")) {
            summary_only = true;
        } else if (eql(a, "-0") or eql(a, "--null")) {
            null_mode = true;
        } else if (a.len > 1 and a[0] == '-') {
            return fail(stderr, "unknown option '{s}'", .{a});
        } else {
            try roots.append(a);
        }
    }
    if (roots.items.len == 0) try roots.append(".");

    for (roots.items) |root| {
        var d = std.fs.cwd().openDir(root, .{}) catch |err|
            return fail(stderr, "cannot open '{s}': {s}", .{ root, @errorName(err) });
        d.close();
    }

    var report = dupes.find(gpa, roots.items, opts) catch |err| {
        return fail(stderr, "scan failed: {s}", .{@errorName(err)});
    };
    defer report.deinit();

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;

    if (null_mode) {
        // Every copy except the first in each group: the ones you could delete.
        for (report.groups) |g| {
            for (g.paths[1..]) |p| try out.print("{s}\x00", .{p});
        }
        return out_buf.flush();
    }

    if (!summary_only) {
        for (report.groups) |g| {
            try out.print("{d} copies of {s}  ({s} reclaimable)\n", .{
                g.paths.len,
                dupes.formatSize(&b1, g.size),
                dupes.formatSize(&b2, g.reclaimable()),
            });
            for (g.paths) |p| try out.print("  {s}\n", .{p});
            try out.writeAll("\n");
        }
    }

    try out.print("{d} files scanned, {d} duplicate group{s}, {s} reclaimable", .{
        report.files_scanned,
        report.groups.len,
        if (report.groups.len == 1) "" else "s",
        dupes.formatSize(&b1, report.totalReclaimable()),
    });
    try out.print(" ({s} read)\n", .{dupes.formatSize(&b2, report.bytes_hashed)});
    if (report.unreadable > 0)
        try out.print("warning: {d} files could not be read\n", .{report.unreadable});
    try out_buf.flush();
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(w: anytype, comptime fmt: []const u8, args: anytype) !void {
    try w.print("dupefind: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    const mult: u64 = switch (std.ascii.toLower(s[s.len - 1])) {
        'k' => 1024,
        'm' => 1024 * 1024,
        'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (mult == 1) s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, n, mult) catch null;
}

test "parseSize" {
    try std.testing.expectEqual(@as(?u64, 10), parseSize("10"));
    try std.testing.expectEqual(@as(?u64, 4096), parseSize("4k"));
    try std.testing.expectEqual(@as(?u64, 2 * 1024 * 1024), parseSize("2M"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("abc"));
    try std.testing.expectEqual(@as(?u64, null), parseSize(""));
}

test {
    _ = dupes;
}
