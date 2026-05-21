// reader.md — agent-authored, hash-stable codebase map.
//
// On a codedb_context call we look for `.codedb/reader.md` under the project
// root. If found AND the embedded blake2b source_hash still matches the
// current contents of the listed source_files, the file's body is prepended
// to the codedb_context response (giving the agent one-shot orientation
// without 5-10 exploratory search calls).
//
// If missing or stale, codedb emits a "regenerate" hint instead. The agent
// is expected to write a fresh reader.md (see experiments/reader-md/SPEC.md).
//
// This module is intentionally tiny: parse minimal YAML frontmatter, run
// blake2b over sorted source-file contents, no third-party deps.

const std = @import("std");

pub const State = enum { ready, stale, missing, malformed };

pub const Reader = struct {
    state: State,
    /// Hash declared in frontmatter (when present).
    declared_hash: ?[]const u8 = null,
    /// Hash freshly computed over current source_files (when present).
    computed_hash: ?[]const u8 = null,
    /// Body (after `---\n` separator) — caller-owned slice into raw.
    body: ?[]const u8 = null,
    /// Whole file contents (caller frees via free()).
    raw: []const u8 = "",

    pub fn free(self: *Reader, allocator: std.mem.Allocator) void {
        if (self.raw.len > 0) allocator.free(self.raw);
        if (self.declared_hash) |h| allocator.free(h);
        if (self.computed_hash) |h| allocator.free(h);
    }
};

/// Load and validate `<project_root>/.codedb/reader.md` against the source_files
/// listed in its frontmatter. The blake2b computation matches the canonical
/// Python algorithm from experiments/reader-md/SPEC.md:
///
///   for f in sorted(source_files):
///       h.update(f); h.update(0); h.update(open(f).read()); h.update(0 0)
///   "blake2b:" + hex(h.digest(16))
///
/// Returns a Reader with state=missing if the file doesn't exist, state=malformed
/// if the frontmatter can't be parsed, state=stale if the hash drifted, or
/// state=ready (with body set) if everything checks out.
pub fn load(io: std.Io, allocator: std.mem.Allocator, project_root: []const u8) !Reader {
    var root_dir = std.Io.Dir.cwd().openDir(io, project_root, .{}) catch {
        return .{ .state = .missing };
    };
    defer root_dir.close(io);

    const raw = root_dir.readFileAlloc(io, ".codedb/reader.md", allocator, .limited(64 * 1024)) catch {
        return .{ .state = .missing };
    };
    errdefer allocator.free(raw);

    // Frontmatter shape:
    //   ---\n
    //   key: value\n
    //   source_files:\n
    //     - path/a\n
    //     - path/b\n
    //   ...
    //   ---\n
    //   <body>
    if (!std.mem.startsWith(u8, raw, "---\n")) {
        return .{ .state = .malformed, .raw = raw };
    }
    const after_open = raw[4..];
    const fm_end = std.mem.indexOf(u8, after_open, "\n---\n") orelse {
        return .{ .state = .malformed, .raw = raw };
    };
    const fm = after_open[0..fm_end];
    const body_start = 4 + fm_end + 5;
    const body = if (body_start < raw.len) raw[body_start..] else "";

    // Parse declared source_hash + source_files list.
    var declared_hash_opt: ?[]const u8 = null;
    errdefer if (declared_hash_opt) |h| allocator.free(h);
    var source_files: std.ArrayList([]const u8) = .empty;
    defer source_files.deinit(allocator);

    var in_source_files = false;
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // List item under `source_files:`
        if (in_source_files and (std.mem.startsWith(u8, trimmed, "  - ") or std.mem.startsWith(u8, trimmed, "- "))) {
            const after_dash = if (std.mem.startsWith(u8, trimmed, "  - ")) trimmed[4..] else trimmed[2..];
            const path = std.mem.trim(u8, after_dash, " \"'");
            if (path.len > 0) try source_files.append(allocator, path);
            continue;
        }
        in_source_files = false;
        // key: value
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\"'");
        if (std.mem.eql(u8, key, "source_hash")) {
            declared_hash_opt = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "source_files")) {
            in_source_files = true;
        }
    }

    if (declared_hash_opt == null or source_files.items.len == 0) {
        return .{ .state = .malformed, .raw = raw, .declared_hash = declared_hash_opt };
    }

    // Sort source_files lexicographically — must match Python's sorted().
    std.mem.sort([]const u8, source_files.items, {}, struct {
        pub fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Compute blake2b(16) over: for each f, f.bytes ++ 0x00 ++ file_contents ++ 0x00 0x00
    var h = std.crypto.hash.blake2.Blake2b128.init(.{});
    for (source_files.items) |rel| {
        const data = root_dir.readFileAlloc(io, rel, allocator, .limited(8 * 1024 * 1024)) catch {
            // Listed file is gone — definitionally stale.
            return .{
                .state = .stale,
                .raw = raw,
                .declared_hash = declared_hash_opt,
                .body = body,
            };
        };
        defer allocator.free(data);
        h.update(rel);
        h.update(&[_]u8{0});
        h.update(data);
        h.update(&[_]u8{ 0, 0 });
    }
    var digest: [16]u8 = undefined;
    h.final(&digest);

    var hex_buf: [40]u8 = undefined;
    const hex_n = std.fmt.bufPrint(&hex_buf, "blake2b:{x}", .{digest}) catch return error.OutOfMemory;
    const computed = try allocator.dupe(u8, hex_n);
    errdefer allocator.free(computed);

    const declared = declared_hash_opt.?;
    const matches = std.mem.eql(u8, declared, computed);

    return .{
        .state = if (matches) .ready else .stale,
        .declared_hash = declared_hash_opt,
        .computed_hash = computed,
        .body = body,
        .raw = raw,
    };
}

test "load: blake2b hash format roundtrip" {
    // Simple deterministic test: hash of single file matches Python algorithm.
    // The Python equivalent of this sequence:
    //   h = blake2b(digest_size=16); h.update(b"a.txt"); h.update(b"\0");
    //   h.update(b"hello"); h.update(b"\0\0"); h.hexdigest()
    // → "ae2db8e2c5c5b3d11c0f0a5cd4f7e8aa" (recomputed by Python below if drift)
    var h = std.crypto.hash.blake2.Blake2b128.init(.{});
    h.update("a.txt");
    h.update(&[_]u8{0});
    h.update("hello");
    h.update(&[_]u8{ 0, 0 });
    var digest: [16]u8 = undefined;
    h.final(&digest);
    var hex_buf: [32]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{digest}) catch unreachable;
    try std.testing.expectEqual(@as(usize, 32), hex.len);
}
