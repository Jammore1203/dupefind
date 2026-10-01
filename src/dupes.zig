//! Duplicate file detection.
//!
//! Files are narrowed down in three passes so that most of them are never
//! read at all:
//!   1. group by size (from the directory walk, no reads)
//!   2. within a size group, hash only the first 4 KiB
//!   3. within a partial-hash group, hash the whole file (BLAKE3)
//! Hard links to the same inode are counted once, since deleting one
//! frees nothing.

const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

pub const Digest = [Blake3.digest_length]u8;

pub const Options = struct {
    /// Ignore files smaller than this many bytes.
    min_size: u64 = 1,
    /// Descend into hidden directories such as .git
    include_hidden: bool = false,
};

pub const Group = struct {
    size: u64,
    paths: [][]const u8,

    /// Bytes freed by keeping one copy and deleting the rest.
    pub fn reclaimable(self: Group) u64 {
        return self.size * (self.paths.len - 1);
    }
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    groups: []Group,
    files_scanned: usize,
    bytes_hashed: u64,
    unreadable: usize,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }

    pub fn totalReclaimable(self: Report) u64 {
        var total: u64 = 0;
        for (self.groups) |g| total += g.reclaimable();
        return total;
    }
};

const Candidate = struct {
    path: []const u8,
    size: u64,
};

const partial_len = 4096;

pub fn find(gpa: std.mem.Allocator, roots: []const []const u8, opts: Options) !Report {
    var report = Report{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .groups = &.{},
        .files_scanned = 0,
        .bytes_hashed = 0,
        .unreadable = 0,
    };
    errdefer report.arena.deinit();
    const arena = report.arena.allocator();

    // ---- pass 1: walk and bucket by size ------------------------------
    var by_size = std.AutoHashMap(u64, std.ArrayListUnmanaged(Candidate)).init(arena);
    var seen_inodes = std.AutoHashMap(std.fs.File.INode, void).init(arena);

    for (roots) |root| {
        var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(arena);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (!opts.include_hidden and isHidden(entry.path)) continue;
            if (entry.kind != .file) continue;

            const stat = entry.dir.statFile(entry.basename) catch {
                report.unreadable += 1;
                continue;
            };
            report.files_scanned += 1;
            if (stat.size < opts.min_size) continue;

            const inode = try seen_inodes.getOrPut(stat.inode);
            if (inode.found_existing) continue;

            const path = if (std.mem.eql(u8, root, "."))
                try arena.dupe(u8, entry.path)
            else
                try std.fs.path.join(arena, &.{ root, entry.path });
            const bucket = try by_size.getOrPut(stat.size);
            if (!bucket.found_existing) bucket.value_ptr.* = .{};
            try bucket.value_ptr.append(arena, .{ .path = path, .size = stat.size });
        }
    }

    // ---- passes 2 and 3: partial hash, then full hash -----------------
    var groups = std.ArrayListUnmanaged(Group){};
    var it = by_size.valueIterator();
    while (it.next()) |same_size| {
        if (same_size.items.len < 2) continue;

        var by_partial = std.AutoHashMap(Digest, std.ArrayListUnmanaged([]const u8)).init(arena);
        for (same_size.items) |c| {
            const digest = hashFile(c.path, partial_len, &report.bytes_hashed) catch {
                report.unreadable += 1;
                continue;
            };
            const e = try by_partial.getOrPut(digest);
            if (!e.found_existing) e.value_ptr.* = .{};
            try e.value_ptr.append(arena, c.path);
        }

        const size = same_size.items[0].size;
        var pit = by_partial.valueIterator();
        while (pit.next()) |same_start| {
            if (same_start.items.len < 2) continue;

            // Small files were read completely by the partial hash.
            if (size <= partial_len) {
                try groups.append(arena, .{ .size = size, .paths = same_start.items });
                continue;
            }

            var by_full = std.AutoHashMap(Digest, std.ArrayListUnmanaged([]const u8)).init(arena);
            for (same_start.items) |path| {
                const digest = hashFile(path, null, &report.bytes_hashed) catch {
                    report.unreadable += 1;
                    continue;
                };
                const e = try by_full.getOrPut(digest);
                if (!e.found_existing) e.value_ptr.* = .{};
                try e.value_ptr.append(arena, path);
            }
            var fit = by_full.valueIterator();
            while (fit.next()) |same| {
                if (same.items.len >= 2)
                    try groups.append(arena, .{ .size = size, .paths = same.items });
            }
        }
    }

    // Biggest wins first, and a stable order for everything else.
    for (groups.items) |g| std.mem.sort([]const u8, g.paths, {}, lessThanStr);
    std.mem.sort(Group, groups.items, {}, groupOrder);

    report.groups = groups.items;
    return report;
}

/// BLAKE3 of the first `limit` bytes of a file (or all of it if null).
pub fn hashFile(path: []const u8, limit: ?u64, counter: *u64) !Digest {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var hasher = Blake3.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var remaining: u64 = limit orelse std.math.maxInt(u64);
    while (remaining > 0) {
        const want: usize = @intCast(@min(buf.len, remaining));
        const n = try file.read(buf[0..want]);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        remaining -= n;
        counter.* += n;
    }
    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

fn isHidden(rel_path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, rel_path, std.fs.path.sep);
    while (parts.next()) |p| {
        if (p.len > 1 and p[0] == '.') return true;
    }
    return false;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn groupOrder(_: void, a: Group, b: Group) bool {
    if (a.reclaimable() != b.reclaimable()) return a.reclaimable() > b.reclaimable();
    return std.mem.lessThan(u8, a.paths[0], b.paths[0]);
}

/// "1.5 MiB", "312 B"
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch unreachable;
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024 and unit < units.len - 1) : (unit += 1) value /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch unreachable;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
    try dir.writeFile(.{ .sub_path = path, .data = data });
}

test "formatSize" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatSize(&buf, 0));
    try testing.expectEqualStrings("1023 B", formatSize(&buf, 1023));
    try testing.expectEqualStrings("1.0 KiB", formatSize(&buf, 1024));
    try testing.expectEqualStrings("1.5 MiB", formatSize(&buf, 1024 * 1024 * 3 / 2));
}

test "isHidden" {
    try testing.expect(isHidden(".git/config"));
    try testing.expect(isHidden("a/.cache/b"));
    try testing.expect(!isHidden("a/b.txt"));
    try testing.expect(!isHidden("./a"));
}

test "finds duplicates and ignores look-alikes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "a.txt", "hello world");
    try writeFile(tmp.dir, "sub/b.txt", "hello world");
    try writeFile(tmp.dir, "sub/deeper/c.txt", "hello world");
    try writeFile(tmp.dir, "same-size.txt", "hello WORLD"); // same size, different bytes
    try writeFile(tmp.dir, "unique.txt", "nothing like the others");
    try writeFile(tmp.dir, ".hidden/d.txt", "hello world");

    // Two large files that only differ after the first 4 KiB, so the
    // partial hash collides and the full hash has to split them.
    var big: [10000]u8 = undefined;
    @memset(&big, 'x');
    try writeFile(tmp.dir, "big1.bin", &big);
    try writeFile(tmp.dir, "big2.bin", &big);
    big[9000] = 'y';
    try writeFile(tmp.dir, "big3.bin", &big);

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var report = try find(testing.allocator, &.{root}, .{});
    defer report.deinit();

    try testing.expectEqual(@as(usize, 2), report.groups.len);

    // Largest reclaimable group first: the two identical big files.
    try testing.expectEqual(@as(u64, 10000), report.groups[0].size);
    try testing.expectEqual(@as(usize, 2), report.groups[0].paths.len);
    try testing.expect(std.mem.endsWith(u8, report.groups[0].paths[0], "big1.bin"));

    // The three "hello world" copies; the hidden one is skipped.
    try testing.expectEqual(@as(usize, 3), report.groups[1].paths.len);
    try testing.expectEqual(@as(u64, 10000 + 2 * 11), report.totalReclaimable());
}

test "hidden directories can be included" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a", "same");
    try writeFile(tmp.dir, ".git/b", "same");

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var without = try find(testing.allocator, &.{root}, .{});
    defer without.deinit();
    try testing.expectEqual(@as(usize, 0), without.groups.len);

    var with = try find(testing.allocator, &.{root}, .{ .include_hidden = true });
    defer with.deinit();
    try testing.expectEqual(@as(usize, 1), with.groups.len);
}

test "min_size filters small files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a", "tiny");
    try writeFile(tmp.dir, "b", "tiny");

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);

    var report = try find(testing.allocator, &.{root}, .{ .min_size = 100 });
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.groups.len);
}

test "hard links are not duplicates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "original", "linked content");

    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    const src = try std.fs.path.join(testing.allocator, &.{ root, "original" });
    defer testing.allocator.free(src);
    const dst = try std.fs.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(dst);
    try std.posix.link(src, dst, 0);

    var report = try find(testing.allocator, &.{root}, .{});
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.groups.len);
}
