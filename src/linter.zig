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

// std.fs / std.posix are not available in this Io-based build, so use libc
// access(2) directly for the PATH probe (libc is already linked; see cio.zig).
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
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
    statuses: std.EnumArray(Language, LinterStatus) = std.EnumArray(Language, LinterStatus).initFill(.unknown),

    pub fn status(self: *const LinterSession, language: Language) LinterStatus {
        return self.statuses.get(language);
    }

    pub fn mark(self: *LinterSession, language: Language, s: LinterStatus) void {
        self.statuses.set(language, s);
    }

    /// True if we should attempt the external linter for `language`: it has a
    /// registered tool and has not already been ruled out this session.
    pub fn shouldTry(self: *const LinterSession, language: Language) bool {
        return linterFor(language) != null and self.statuses.get(language) != .unavailable;
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
