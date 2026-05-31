//! Per-language linter registry + session policy (trial/graph-based-codedb).
//!
//! Tier-1 of post-edit verification. The in-process heuristics in edit.zig
//! (Tier-0: delimiter balance + dropped-import scan) are instant and always
//! on, but they only catch structural breaks. When a fast external linter is
//! present it gives REAL diagnostics — undefined names, type/lint errors —
//! that the heuristics cannot.
//!
//! Design constraint: add ZERO weight to the synchronous edit path. Linter
//! choice and availability are decided here (pure, cheap); the actual run
//! happens off the hot path. Any failure — tool missing, install failed, or a
//! crash/timeout — flips that language to `.unavailable` for the rest of the
//! SESSION via `LinterSession`, so codedb silently falls back to the Tier-0
//! heuristics and never pays the cost again.
//!
//! The CLI invocations were confirmed against the upstream docs (ruff,
//! biome) via deepwiki; the rest use the language toolchain's own fast
//! single-file syntax check. Languages without a good single-file checker
//! return null here and simply use the heuristics.

const std = @import("std");
const Language = @import("explore.zig").Language;
const cio = @import("cio.zig");
const linter_pref = @import("linter_pref.zig");

// std.fs / std.posix are not available in this Io-based build, so use libc
// access(2) directly for the PATH probe (libc is already linked; see cio.zig).
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn usleep(usec: c_uint) c_int;
const X_OK: c_int = 1;

/// The "{file}" token in check_args is replaced with the target path at run time.
pub const FILE_TOKEN = "{file}";

pub const LinterSpec = struct {
    /// Executable looked up on PATH.
    tool: []const u8,
    /// Argv (after the tool) to check one file and emit machine-readable output.
    check_args: []const []const u8,
    /// What to run / suggest to obtain the tool when it is missing.
    install_hint: []const u8,
    /// True when check_args yields JSON (vs plain compiler diagnostics).
    json: bool = false,
};

/// The linter codedb prefers for a language, or null to use only the
/// in-process heuristics. ruff/biome confirmed via deepwiki; the others use the
/// toolchain's own single-file check (no project context required).
pub fn linterFor(language: Language) ?LinterSpec {
    return switch (language) {
        .python => .{
            .tool = "ruff",
            .check_args = &.{ "check", FILE_TOKEN, "--output-format", "json" },
            .install_hint = "uv tool install ruff  (or: pip install ruff)",
            .json = true,
        },
        .javascript, .typescript => .{
            .tool = "biome",
            .check_args = &.{ "lint", "--reporter=json", FILE_TOKEN },
            .install_hint = "npm i -g @biomejs/biome  (or download the standalone biome binary)",
            .json = true,
        },
        .zig => .{
            .tool = "zig",
            .check_args = &.{ "ast-check", FILE_TOKEN },
            .install_hint = "ships with the Zig toolchain",
        },
        .go_lang => .{
            // gofmt -e reports syntax errors for a single file without needing a
            // built package (unlike `go vet`).
            .tool = "gofmt",
            .check_args = &.{ "-l", "-e", FILE_TOKEN },
            .install_hint = "ships with the Go toolchain",
        },
        .ruby => .{
            .tool = "ruby",
            .check_args = &.{ "-c", FILE_TOKEN },
            .install_hint = "ships with Ruby",
        },
        .php => .{
            .tool = "php",
            .check_args = &.{ "-l", FILE_TOKEN },
            .install_hint = "ships with PHP",
        },
        // c/cpp/rust/java/kotlin/swift/dart: no reliable single-file linter
        // without project context — fall back to Tier-0 heuristics for now.
        else => null,
    };
}

pub const LinterStatus = enum {
    /// Not yet probed this session.
    unknown,
    /// Tool present and working — run it.
    available,
    /// Missing, install failed, or it crashed/timed out — use heuristics only
    /// for the rest of the session. Sticky: never retried.
    unavailable,
};

/// Per-session availability cache. One LinterSession lives for the lifetime of
/// the MCP server connection. Once a language is marked `.unavailable` it stays
/// that way, guaranteeing the linter is probed/installed at most once and that
/// a flaky or absent tool can never repeatedly tax the edit path.
pub const LinterSession = struct {
    /// Remembered user preference (persisted in config). External linters are
    /// installed only at codedb install / `codedb update` time, behind a prompt;
    /// the MCP server never installs anything and never prompts. When the user
    /// declined (or hasn't opted in), this stays false and codedb uses only the
    /// Tier-0 heuristics — the edit path carries zero linter cost.
    enabled: bool = false,
    /// Guards `statuses`: the main thread reads via shouldTry()/status() while a
    /// detached worker writes via mark(). `enabled` is set once at startup and
    /// then read-only, so it needs no lock.
    mu: cio.Mutex = .{},
    statuses: std.EnumArray(Language, LinterStatus) = std.EnumArray(Language, LinterStatus).initFill(.unknown),

    pub fn status(self: *LinterSession, language: Language) LinterStatus {
        self.mu.lock();
        defer self.mu.unlock();
        return self.statuses.get(language);
    }

    pub fn mark(self: *LinterSession, language: Language, s: LinterStatus) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.statuses.set(language, s);
    }

    /// True if we should attempt the external linter for `language`: the user
    /// opted in, the language has a registered tool, and it has not already been
    /// ruled out this session (missing/failed/crashed -> naive heuristics).
    pub fn shouldTry(self: *LinterSession, language: Language) bool {
        if (!self.enabled) return false;
        if (linterFor(language) == null) return false;
        self.mu.lock();
        defer self.mu.unlock();
        return self.statuses.get(language) != .unavailable;
    }
};

/// Best-effort check whether `name` is an executable on PATH. Pure lookup, no
/// spawn. Used to decide between running the linter and (optionally) installing
/// it. Returns false on any error so callers degrade to heuristics.
pub fn toolOnPath(allocator: std.mem.Allocator, name: []const u8) bool {
    const path_env = cio.posixGetenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrint(allocator, "{s}/{s}\x00", .{ dir, name }) catch continue;
        defer allocator.free(full);
        const cpath: [*:0]const u8 = @ptrCast(full.ptr);
        if (access(cpath, X_OK) == 0) return true;
    }
    return false;
}

// ── Execution + output parsing (Tier-1 run, off the hot path) ─────────────

pub const RunError = error{ NoLinter, SpawnFailed, LinterCrashed, OutOfMemory };

/// argv to install the linter for `language`, or null when it ships with a
/// toolchain / has no one-shot installer. Static — nothing to free. Only the
/// two recommended installable tools are returned (ruff, biome).
pub fn installFor(language: Language) ?[]const []const u8 {
    return switch (language) {
        .python => &.{ "uv", "tool", "install", "ruff" },
        .javascript, .typescript => &.{ "npm", "i", "-g", "@biomejs/biome" },
        else => null,
    };
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn clip(s: []const u8, max: usize) []const u8 {
    return s[0..@min(s.len, max)];
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn rowField(o: std.json.ObjectMap) i64 {
    const loc = o.get("location") orelse return 0;
    if (loc != .object) return 0;
    const r = loc.object.get("row") orelse return 0;
    return if (r == .integer) r.integer else 0;
}

fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return trimmed[0..end];
}

/// Summarize `ruff check --output-format json` output (a JSON array of
/// diagnostics). Returns an owned one-line summary, or null when the array is
/// empty (clean). Errors on malformed JSON. Pure — exposed for tests.
pub fn summarizeRuffJson(allocator: std.mem.Allocator, stdout: []const u8) RunError!?[]u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.LinterCrashed;
    defer parsed.deinit();
    if (parsed.value != .array) return error.LinterCrashed;
    const items = parsed.value.array.items;
    if (items.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendFmt(allocator, &buf, "ruff {d} issue{s} -", .{ items.len, plural(items.len) });
    const show = @min(items.len, 3);
    var i: usize = 0;
    while (i < show) : (i += 1) {
        if (items[i] != .object) continue;
        const o = items[i].object;
        const code = strField(o, "code") orelse "?";
        const msg = strField(o, "message") orelse "";
        try appendFmt(allocator, &buf, " {s} {s} at L{d}{s}", .{ code, clip(msg, 48), rowField(o), if (i + 1 < show) "," else "" });
    }
    if (items.len > show) try appendFmt(allocator, &buf, " (+{d} more)", .{items.len - show});
    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Summarize `biome lint --reporter=json` output (an object with a
/// `diagnostics` array). biome reports byte spans, not line numbers, so only
/// the rule category is shown. null = clean. Pure — exposed for tests.
pub fn summarizeBiomeJson(allocator: std.mem.Allocator, stdout: []const u8) RunError!?[]u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.LinterCrashed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.LinterCrashed;
    const diags_v = parsed.value.object.get("diagnostics") orelse return null;
    if (diags_v != .array) return error.LinterCrashed;
    const items = diags_v.array.items;
    if (items.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendFmt(allocator, &buf, "biome {d} issue{s} -", .{ items.len, plural(items.len) });
    const show = @min(items.len, 3);
    var i: usize = 0;
    while (i < show) : (i += 1) {
        if (items[i] != .object) continue;
        const cat = strField(items[i].object, "category") orelse "lint";
        try appendFmt(allocator, &buf, " {s}{s}", .{ clip(cat, 60), if (i + 1 < show) "," else "" });
    }
    if (items.len > show) try appendFmt(allocator, &buf, " (+{d} more)", .{items.len - show});
    return buf.toOwnedSlice(allocator) catch error.OutOfMemory;
}

/// Run the registered linter for `language` on `abs_path` and fold the result
/// into a SHORT owned summary string, or null when the file is clean. Spawns a
/// subprocess (via cio.runCapture, which itself uses a drain thread) — MUST be
/// called off the synchronous edit path. Caller frees the returned slice and,
/// on error, marks the language .unavailable in its LinterSession.
pub fn runCheck(allocator: std.mem.Allocator, language: Language, abs_path: []const u8) RunError!?[]u8 {
    const spec = linterFor(language) orelse return error.NoLinter;

    var argv = allocator.alloc([]const u8, spec.check_args.len + 1) catch return error.OutOfMemory;
    defer allocator.free(argv);
    argv[0] = spec.tool;
    for (spec.check_args, 0..) |a, i| {
        argv[i + 1] = if (std.mem.eql(u8, a, FILE_TOKEN)) abs_path else a;
    }

    const res = cio.runCapture(.{ .allocator = allocator, .argv = argv, .max_output_bytes = 256 * 1024 }) catch return error.SpawnFailed;
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    // A linter killed by a signal (segfault/OOM) is .Signal/.Stopped — treat
    // every non-.Exited outcome as a crash so the caller disables it.
    const code: u8 = switch (res.term) {
        .Exited => |c| c,
        else => return error.LinterCrashed,
    };

    if (spec.json) {
        if (std.mem.eql(u8, spec.tool, "ruff")) {
            // ruff: 0 = clean, 1 = violations, >=2 = usage/internal error.
            if (code >= 2 and std.mem.trim(u8, res.stdout, " \t\r\n").len == 0) return error.LinterCrashed;
            return summarizeRuffJson(allocator, res.stdout);
        }
        return summarizeBiomeJson(allocator, res.stdout);
    }

    // Exit-code tools (zig ast-check, gofmt -e, ruby -c, php -l): 0 = clean.
    if (code == 0) return null;
    const line = firstLine(if (res.stderr.len > 0) res.stderr else res.stdout);
    return std.fmt.allocPrint(allocator, "{s} check failed - {s}", .{ spec.tool, clip(line, 120) }) catch error.OutOfMemory;
}

// ── Install / update-time opt-in prompt (interactive CLI only) ────────────

fn installToolIfMissing(allocator: std.mem.Allocator, out: cio.File, name: []const u8, argv_opt: ?[]const []const u8) void {
    if (toolOnPath(allocator, name)) {
        out.print("  {s}: already installed\n", .{name}) catch {};
        return;
    }
    const argv = argv_opt orelse return;
    if (!toolOnPath(allocator, argv[0])) {
        out.print("  {s}: skipped ({s} not found — install it, then re-run `codedb update`)\n", .{ name, argv[0] }) catch {};
        return;
    }
    out.print("  installing {s} via {s} (this may take a moment)...\n", .{ name, argv[0] }) catch {};
    const res = cio.runCapture(.{ .allocator = allocator, .argv = argv, .max_output_bytes = 256 * 1024 }) catch {
        out.print("  {s}: install failed (could not run {s})\n", .{ name, argv[0] }) catch {};
        return;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    const ok = switch (res.term) {
        .Exited => |c| c == 0,
        else => false,
    };
    out.print("  {s}: {s}\n", .{ name, if (ok) "installed" else "install failed" }) catch {};
}

/// Interactive opt-in for the external-linter bridge, run from the CLI install /
/// `codedb update` path. No-op unless BOTH stdin and stdout are TTYs (so it never
/// fires in the MCP server, CI, or a curl|bash pipe) and the preference is still
/// unset (asked at most once; the remembered choice is respected thereafter).
/// On yes: installs ruff + biome if missing and records the preference; on no:
/// records the decline. Best-effort — never fails the caller.
pub fn maybePromptAndInstall(io: std.Io, allocator: std.mem.Allocator) void {
    if (!cio.File.stdin().isTty() or !cio.File.stdout().isTty()) return;
    if (linter_pref.read(io, allocator) != .unset) return;

    const out = cio.File.stdout();
    out.print("\ncodedb can run fast linters (ruff for Python, biome for JS/TS, ...) after edits\nto catch real errors (undefined names, type/lint issues) on top of its built-in\nchecks. Install the recommended linters now? [y/N] ", .{}) catch return;

    var buf: [64]u8 = undefined;
    const line = cio.readLine(&buf) orelse {
        linter_pref.write(io, allocator, .off);
        return;
    };
    const yes = line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
    if (!yes) {
        out.print("Skipping — codedb will use its built-in heuristics. Re-run `codedb update` to change.\n", .{}) catch {};
        linter_pref.write(io, allocator, .off);
        return;
    }

    installToolIfMissing(allocator, out, "ruff", installFor(.python));
    installToolIfMissing(allocator, out, "biome", installFor(.javascript));
    linter_pref.write(io, allocator, .on);
    out.print("Enabled. codedb will run available linters after edits (built-in checks always run).\n", .{}) catch {};
}

// ── Diagnostics cache (off-hot-path results, delivered out of band) ───────
//
// Holds the latest linter summary per file so the edit/read handlers can
// piggyback it and the codedb_diagnostics tool can pull it. Mutex-guarded
// because the producer is a detached worker thread and the consumers are the
// request handlers. Bounded (LRU by timestamp) so it can't grow without limit.
// `inflight` lets the owner drain in-flight workers before freeing the cache.

pub const DiagnosticsCache = struct {
    pub const MAX = 16;
    pub const FRESH_MS: i64 = 60_000;

    const Entry = struct { path: []u8, hash: u64, summary: []u8, stamp_ms: i64 };

    mu: cio.Mutex = .{},
    alloc: std.mem.Allocator,
    entries: [MAX]?Entry = .{null} ** MAX,
    pending: [MAX]?[]u8 = .{null} ** MAX,
    inflight: usize = 0,

    pub fn init(alloc: std.mem.Allocator) DiagnosticsCache {
        return .{ .alloc = alloc };
    }

    /// Drain in-flight workers, then free every owned slice. Call once at
    /// connection teardown — after this the cache must not be used again.
    pub fn deinit(self: *DiagnosticsCache) void {
        self.drain();
        self.mu.lock();
        defer self.mu.unlock();
        for (&self.entries) |*e| if (e.*) |entry| {
            self.alloc.free(entry.path);
            self.alloc.free(entry.summary);
            e.* = null;
        };
        for (&self.pending) |*p| if (p.*) |path| {
            self.alloc.free(path);
            p.* = null;
        };
    }

    fn isFresh(stamp_ms: i64) bool {
        return cio.milliTimestamp() - stamp_ms < FRESH_MS;
    }

    fn pendingRemoveLocked(self: *DiagnosticsCache, path: []const u8) void {
        for (&self.pending) |*p| {
            if (p.*) |pp| if (std.mem.eql(u8, pp, path)) {
                self.alloc.free(pp);
                p.* = null;
                if (self.inflight > 0) self.inflight -= 1;
                return;
            };
        }
    }

    /// Decide whether to spawn a worker for (path, content_hash). Returns false
    /// (do NOT spawn) when a fresh result for that exact content already exists
    /// or a worker for the path is already in flight; otherwise records the path
    /// as pending and returns true. Caller must later call store() or endWork().
    pub fn tryBeginWork(self: *DiagnosticsCache, path: []const u8, content_hash: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries) |e| if (e) |entry| {
            if (entry.hash == content_hash and std.mem.eql(u8, entry.path, path) and isFresh(entry.stamp_ms)) return false;
        };
        for (self.pending) |p| if (p) |pp| {
            if (std.mem.eql(u8, pp, path)) return false;
        };
        for (&self.pending) |*slot| {
            if (slot.* == null) {
                slot.* = self.alloc.dupe(u8, path) catch return false;
                self.inflight += 1;
                return true;
            }
        }
        return false; // pending table full — skip, stay bounded
    }

    /// Clear the pending mark for a path whose worker finished without a result.
    pub fn endWork(self: *DiagnosticsCache, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.pendingRemoveLocked(path);
    }

    /// Store a worker's result (clears pending, dups path+summary, evicts LRU
    /// when full). Replaces any existing entry for the same path.
    pub fn store(self: *DiagnosticsCache, path: []const u8, content_hash: u64, summary: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.pendingRemoveLocked(path);

        const pdup = self.alloc.dupe(u8, path) catch return;
        const sdup = self.alloc.dupe(u8, summary) catch {
            self.alloc.free(pdup);
            return;
        };

        var slot: ?usize = null;
        for (self.entries, 0..) |e, i| {
            if (e) |entry| if (std.mem.eql(u8, entry.path, path)) {
                slot = i;
                break;
            };
        }
        if (slot == null) for (self.entries, 0..) |e, i| {
            if (e == null) {
                slot = i;
                break;
            }
        };
        if (slot == null) {
            var oldest: usize = 0;
            var oldest_ms: i64 = std.math.maxInt(i64);
            for (self.entries, 0..) |e, i| if (e) |entry| {
                if (entry.stamp_ms < oldest_ms) {
                    oldest_ms = entry.stamp_ms;
                    oldest = i;
                }
            };
            slot = oldest;
        }
        const si = slot.?;
        if (self.entries[si]) |old| {
            self.alloc.free(old.path);
            self.alloc.free(old.summary);
        }
        self.entries[si] = .{ .path = pdup, .hash = content_hash, .summary = sdup, .stamp_ms = cio.milliTimestamp() };
    }

    /// Append the summary for (path, content_hash) to `out` iff a fresh entry
    /// for that exact content exists. Used to piggyback on edit/read of the
    /// same bytes. Returns whether anything was appended.
    pub fn appendIfFresh(self: *DiagnosticsCache, out_alloc: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, content_hash: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries) |e| if (e) |entry| {
            if (entry.hash == content_hash and std.mem.eql(u8, entry.path, path) and isFresh(entry.stamp_ms)) {
                out.appendSlice(out_alloc, entry.summary) catch return false;
                return true;
            }
        };
        return false;
    }

    /// Append the latest summary for `path` regardless of hash (for the
    /// codedb_diagnostics pull tool). Returns whether anything was appended.
    pub fn appendLatest(self: *DiagnosticsCache, out_alloc: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var best: ?Entry = null;
        for (self.entries) |e| if (e) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                if (best == null or entry.stamp_ms > best.?.stamp_ms) best = entry;
            }
        };
        if (best) |entry| {
            out.appendSlice(out_alloc, entry.summary) catch return false;
            return true;
        }
        return false;
    }

    /// Block (bounded ~2s) until no workers are in flight. Called by deinit so a
    /// detached worker can never touch the cache after it is freed.
    pub fn drain(self: *DiagnosticsCache) void {
        var spins: usize = 0;
        while (spins < 2000) : (spins += 1) {
            self.mu.lock();
            const n = self.inflight;
            self.mu.unlock();
            if (n == 0) return;
            _ = usleep(1000); // 1ms; only reached at shutdown while workers finish

        }
    }
};
