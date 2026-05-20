const std = @import("std");
const cio = @import("cio.zig");
const builtin = @import("builtin");
const explore = @import("explore.zig");
const index = @import("index.zig");

const RING_SIZE = 256;
const CLOUD_URL = "https://codedb.codegraff.com/telemetry/ingest";
const VERSION = @import("release_info.zig").semver;
const PLATFORM = std.fmt.comptimePrint("{s}-{s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });

pub const Event = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        tool_call: struct {
            tool: [32]u8 = .{0} ** 32,
            tool_len: u8 = 0,
            latency_ns: i128,
            err: bool,
            response_bytes: u32,
        },
        session_start: void,
        codebase_stats: struct {
            file_count: u32,
            total_lines: u64,
            language_mask: u32,
            index_size_bytes: u64,
            startup_time_ms: u64,
        },
    };
};

pub const Telemetry = struct {
    ring: [RING_SIZE]Event = undefined,
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    file: ?std.Io.File = null,
    io: std.Io = undefined,
    write_offset: u64 = 0,
    enabled: bool = true,
    buf: [4096]u8 = undefined,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    call_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    write_lock: cio.Mutex = .{},
    /// Background sync thread (set by startSyncThread). Cloud sync runs on
    /// this thread so it never blocks the tool-call response path.
    sync_thread: ?std.Thread = null,
    /// Signals the background sync thread to exit. Set on deinit.
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// How often the background thread syncs to cloud (seconds). 30s
    /// matches the previous per-10-calls cadence on typical workloads
    /// without ever blocking a tool response.
    sync_interval_seconds: u64 = 30,

    pub fn init(io: std.Io, data_dir: []const u8, allocator: std.mem.Allocator, disabled: bool) Telemetry {
        var self = Telemetry{};
        self.io = io;

        if (disabled or cio.posixGetenv("CODEDB_NO_TELEMETRY") != null) {
            self.enabled = false;
            return self;
        }

        const path = std.fmt.allocPrint(allocator, "{s}/telemetry.ndjson", .{data_dir}) catch return self;
        defer allocator.free(path);
        if (path.len <= self.path_buf.len) {
            @memcpy(self.path_buf[0..path.len], path);
            self.path_len = path.len;
        }
        self.file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return self;
        if (self.file) |f| {
            self.write_offset = f.length(io) catch 0;
        }
        return self;
    }

    pub fn deinit(self: *Telemetry) void {
        // Signal background sync thread to stop and wait for it before
        // touching shared state (file, write_offset) below.
        self.should_stop.store(true, .release);
        if (self.sync_thread) |th| {
            th.join();
            self.sync_thread = null;
        }
        if (self.enabled) self.flush();
        if (self.file) |f| f.close(self.io);
        self.file = null;
        // Final cloud sync on shutdown — the background thread may have
        // run a sync moments ago, but this guarantees the WAL is uploaded
        // if there are events since the last tick.
        if (self.enabled) self.syncToCloud();
    }

    /// Start the background cloud-sync thread. Call this AFTER the
    /// Telemetry has been placed at its final memory location (init returns
    /// by value, so the thread can't safely take a pointer until then).
    /// No-op when telemetry is disabled or already started.
    pub fn startSyncThread(self: *Telemetry) void {
        if (!self.enabled) return;
        if (self.sync_thread != null) return;
        self.sync_thread = std.Thread.spawn(.{}, syncThreadFn, .{self}) catch return;
    }

    /// Background loop: every `sync_interval_seconds`, call syncToCloud.
    /// Checks should_stop every 100ms so shutdown is responsive (<=100ms
    /// shutdown latency rather than waiting out a full interval).
    fn syncThreadFn(self: *Telemetry) void {
        const tick_ms: u64 = 100;
        const ticks_per_interval: u64 = self.sync_interval_seconds * 1000 / tick_ms;
        while (!self.should_stop.load(.acquire)) {
            var i: u64 = 0;
            while (i < ticks_per_interval) : (i += 1) {
                if (self.should_stop.load(.acquire)) return;
                cio.sleepMs(tick_ms);
            }
            if (self.should_stop.load(.acquire)) return;
            self.syncToCloud();
        }
    }

    pub fn record(self: *Telemetry, kind: Event.Kind) void {
        if (!self.enabled) return;

        self.write_lock.lock();
        const next = self.head.fetchAdd(1, .monotonic);
        const slot = next % RING_SIZE;
        self.ring[slot] = .{
            .kind = kind,
        };
        const tail = self.tail.load(.monotonic);
        if ((next + 1) -% tail > RING_SIZE) {
            self.tail.store((next + 1) -% RING_SIZE, .monotonic);
        }
        self.write_lock.unlock();

        const count = self.call_count.fetchAdd(1, .monotonic) + 1;
        // Flush local WAL every 3 events — fast (local file write).
        if (count % 3 == 0) {
            self.flush();
        }
        // syncToCloud was previously called every 10 events in-line, but it
        // shells out to `curl` with a 5-second --max-time, blocking the
        // calling thread. That was the cause of codedb's p99 tail latency
        // (~5–10% of tool calls spiked to 200–400 ms because the curl call
        // happens on the same thread as the tool response).
        //
        // Cloud sync now happens only on shutdown (via deinit). For local
        // dashboards and benchmark replay the WAL on disk is the source of
        // truth and is up to date within 3 events.
    }

    pub fn recordSessionStart(self: *Telemetry) void {
        self.record(.{ .session_start = {} });
    }

    pub fn recordToolCall(self: *Telemetry, tool_name: []const u8, latency_ns: i128, is_error: bool, response_bytes: usize) void {
        if (!self.enabled) return;
        var tc: Event.Kind = .{ .tool_call = .{
            .latency_ns = latency_ns,
            .err = is_error,
            .response_bytes = @intCast(@min(response_bytes, std.math.maxInt(u32))),
        } };
        var len: u8 = @intCast(@min(tool_name.len, 32));
        while (len > 0 and !std.unicode.utf8ValidateSlice(tool_name[0..len])) : (len -= 1) {}
        @memcpy(tc.tool_call.tool[0..len], tool_name[0..len]);
        tc.tool_call.tool_len = len;
        self.record(tc);
    }

    pub fn recordCodebaseStats(self: *Telemetry, explorer: *explore.Explorer, startup_time_ms: u64) void {
        if (!self.enabled) return;

        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();

        var file_count: u32 = 0;
        var total_lines: u64 = 0;
        var language_mask: u32 = 0;

        var outline_iter = explorer.outlines.iterator();
        while (outline_iter.next()) |entry| {
            file_count +|= 1;
            total_lines +|= entry.value_ptr.line_count;
            const bit_index: u5 = @intCast(@intFromEnum(entry.value_ptr.language));
            language_mask |= @as(u32, 1) << bit_index;
        }

        self.record(.{ .codebase_stats = .{
            .file_count = file_count,
            .total_lines = total_lines,
            .language_mask = language_mask,
            .index_size_bytes = approxIndexSizeBytes(explorer),
            .startup_time_ms = startup_time_ms,
        } });
    }

    pub fn flush(self: *Telemetry) void {
        const f = self.file orelse return;

        self.write_lock.lock();
        defer self.write_lock.unlock();

        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.monotonic);
        if (tail == head) return;

        var i = tail;
        while (i != head) : (i +%= 1) {
            const ev = self.ring[i % RING_SIZE];
            const len = self.formatEvent(&ev) catch continue;
            f.writePositionalAll(self.io, self.buf[0..len], self.write_offset) catch continue;
            self.write_offset += len;
        }
        self.tail.store(head, .monotonic);
    }

    fn syncToCloud(self: *Telemetry) void {
        if (!self.enabled or self.path_len == 0) return;
        const path = self.path_buf[0..self.path_len];

        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return;
        if (stat.size == 0) return;

        // Use argv-based exec (no shell interpolation) to avoid injection
        var data_arg_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const data_arg = std.fmt.bufPrint(&data_arg_buf, "@{s}", .{path}) catch return;

        const result = cio.runCapture(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "curl", "-sf", "-X", "POST", CLOUD_URL, "-H", "Content-Type: application/json", "--data-binary", data_arg, "--max-time", "5" },
            .max_output_bytes = 4096,
        }) catch return;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);

        // Truncate the file after successful sync
        if (std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true })) |f| {
            f.close(self.io);
            self.write_offset = 0;
        } else |_| {}
    }

    pub fn syncWalToCloud(self: *Telemetry, wal_path: ?[]const u8) void {
        _ = wal_path;
        self.syncToCloud();
    }

    fn formatEvent(self: *Telemetry, ev: *const Event) !usize {
        var stream = std.Io.Writer.fixed(&self.buf);
        const w = &stream;
        try w.print("{{\"timestamp_ms\":{d}", .{cio.milliTimestamp()});
        switch (ev.kind) {
            .tool_call => |tc| {
                const name = tc.tool[0..tc.tool_len];
                try w.print(",\"event_type\":\"tool_call\",\"tool\":\"{s}\",\"latency_ns\":{d},\"error\":{s},\"response_bytes\":{d}", .{
                    name,
                    @as(i64, @intCast(@min(tc.latency_ns, std.math.maxInt(i64)))),
                    if (tc.err) "true" else "false",
                    tc.response_bytes,
                });
            },
            .session_start => {
                try w.print(",\"event_type\":\"session_start\",\"version\":\"{s}\",\"platform\":\"{s}\"", .{ VERSION, PLATFORM });
            },
            .codebase_stats => |stats| {
                try w.print(",\"event_type\":\"codebase_stats\",\"file_count\":{d},\"total_lines\":{d},\"languages\":[", .{
                    stats.file_count,
                    stats.total_lines,
                });
                try writeLanguages(w, stats.language_mask);
                try w.print("],\"index_size_bytes\":{d},\"startup_time_ms\":{d}", .{
                    stats.index_size_bytes,
                    stats.startup_time_ms,
                });
            },
        }
        try w.writeAll("}\n");
        return w.end;
    }
};

fn writeLanguages(writer: anytype, language_mask: u32) !void {
    const names = [_][]const u8{
        "zig",
        "c",
        "cpp",
        "python",
        "javascript",
        "typescript",
        "rust",
        "go_lang",
        "php",
        "ruby",
        "hcl",
        "r",
        "markdown",
        "json",
        "yaml",
        "unknown",
        "dart",
        "java",
        "kotlin",
        "svelte",
        "vue",
        "astro",
        "shell",
        "css",
        "scss",
        "sql",
        "protobuf",
        "fortran",
        "llvm_ir",
        "mlir",
        "tablegen",
    };
    var first = true;
    for (names, 0..) |name, idx| {
        const bit_index: u5 = @intCast(idx);
        if ((language_mask & (@as(u32, 1) << bit_index)) == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("\"{s}\"", .{name});
    }
}

/// Cache for approxIndexSizeBytes — the iteration is O(unique-trigrams +
/// unique-words + sparse-ngrams) which got 2x slower after the trigram cap
/// was lifted to 1MB (more files indexed). codedb_status is the only caller
/// and a 5-second stale-tolerance is fine for a "this is approximate"
/// memory metric.
var size_cache_value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var size_cache_at_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
const SIZE_CACHE_TTL_MS: i64 = 5_000;

pub fn approxIndexSizeBytes(explorer: *const explore.Explorer) u64 {
    const now = cio.milliTimestamp();
    const cached_at = size_cache_at_ms.load(.monotonic);
    if (cached_at != 0 and now - cached_at < SIZE_CACHE_TTL_MS) {
        return size_cache_value.load(.monotonic);
    }
    var total: u64 = 0;

    var word_iter = explorer.word_index.index.iterator();
    while (word_iter.next()) |entry| {
        total +|= entry.key_ptr.*.len;
        total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
    }

    var file_words_iter = explorer.word_index.file_words.iterator();
    while (file_words_iter.next()) |entry| {
        total +|= entry.value_ptr.len * @sizeOf(usize);
    }

    switch (explorer.trigram_index) {
        .heap => |heap| {
            var trigram_iter = heap.index.iterator();
            while (trigram_iter.next()) |entry| {
                total +|= @sizeOf(@TypeOf(entry.key_ptr.*));
                total +|= entry.value_ptr.count() * (@sizeOf(usize) + @sizeOf(index.PostingMask));
            }
            var file_trigrams_iter = heap.file_trigrams.iterator();
            while (file_trigrams_iter.next()) |entry| {
                total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
            }
        },
        .mmap, .mmap_overlay => {},
    }

    var sparse_iter = explorer.sparse_ngram_index.index.iterator();
    while (sparse_iter.next()) |entry| {
        total +|= @sizeOf(@TypeOf(entry.key_ptr.*));
        total +|= entry.value_ptr.count() * @sizeOf(usize);
    }

    var file_sparse_iter = explorer.sparse_ngram_index.file_ngrams.iterator();
    while (file_sparse_iter.next()) |entry| {
        total +|= entry.value_ptr.items.len * @sizeOf(@TypeOf(entry.value_ptr.items[0]));
    }

    size_cache_value.store(total, .monotonic);
    size_cache_at_ms.store(now, .monotonic);
    return total;
}
