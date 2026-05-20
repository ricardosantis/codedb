#!/usr/bin/env python3
"""
search-shootout: codedb vs SQLite FTS5 (trigram + unicode61) vs lean-ctx

Usage:
    python3 shootout.py --corpus /path/to/corpus [--out results/foo.md]
                        [--skip-leanctx] [--skip-codedb] [--iters N]

Measures, per backend:
    - cold-index wall time
    - on-disk index size
    - per-query p50/p99 warm latency
    - hit count (sanity / recall proxy)

Backend notes:
    codedb        — warm via MCP stdio (one server process, many calls)
    fts5_*        — warm via persistent SQLite connection (one process)
    lean-ctx grep — cold via CLI spawn per call (includes ~700ms binary
                    startup); lean-ctx uses a daemon under the hood for the
                    actual search work, but each `lean-ctx grep` invocation
                    still pays binary startup
"""

import argparse, json, os, re, select, shutil, sqlite3, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
DEFAULT_CODEDB = REPO_ROOT / "zig-out/bin/codedb"
DEFAULT_LEANCTX = shutil.which("lean-ctx")
QUERIES_PATH = HERE / "queries.json"
NL = chr(10)

INDEXABLE_EXTS = {
    ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
    ".py", ".go", ".rs", ".c", ".h", ".cc", ".cpp", ".hpp", ".zig",
    ".md", ".json", ".css", ".scss", ".html", ".yaml", ".yml", ".toml",
}
SKIP_DIRS = {
    ".git", "node_modules", "dist", "build", ".next", "out",
    "zig-out", ".zig-cache", "__pycache__", "target", ".turbo",
    ".cache", "coverage",
}


def walk_corpus(root):
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if Path(f).suffix.lower() in INDEXABLE_EXTS:
                yield Path(dirpath) / f


# ---------------- FTS5 ----------------
def build_fts5(corpus, db_path, tokenizer):
    if db_path.exists():
        db_path.unlink()
    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute(
        "CREATE VIRTUAL TABLE files USING fts5(path, body, tokenize=" + repr(tokenizer) + ")"
    )
    start = time.perf_counter()
    n = 0
    batch = []
    with conn:
        for p in walk_corpus(corpus):
            try:
                body = p.read_text(errors="ignore")
            except Exception:
                continue
            batch.append((str(p.relative_to(corpus)), body))
            n += 1
            if len(batch) >= 200:
                conn.executemany("INSERT INTO files(path, body) VALUES (?, ?)", batch)
                batch.clear()
        if batch:
            conn.executemany("INSERT INTO files(path, body) VALUES (?, ?)", batch)
    elapsed = time.perf_counter() - start
    conn.close()
    return elapsed, n, db_path.stat().st_size


def fts5_match_expr(q):
    safe = q.replace('"', '""')
    return '"' + safe + '"'


def query_fts5(db_path, tokenizer, q, iters):
    conn = sqlite3.connect(str(db_path))
    cur = conn.cursor()
    match = fts5_match_expr(q)
    try:
        cur.execute("SELECT count(*) FROM files WHERE files MATCH ?", (match,))
        count = cur.fetchone()[0]
    except sqlite3.OperationalError:
        conn.close()
        return [], -1
    times = []
    for _ in range(iters):
        s = time.perf_counter()
        cur.execute("SELECT count(*) FROM files WHERE files MATCH ?", (match,))
        cur.fetchone()
        times.append((time.perf_counter() - s) * 1000.0)
    conn.close()
    return times, count


# ---------------- codedb ----------------
class CodedbMCP:
    def __init__(self, bin_path, root):
        # codedb argv order: [root] <command>
        self.proc = subprocess.Popen(
            [bin_path, root, "mcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
        )
        self.id = 0
        self.buf = b""
        self._init()

    def _send(self, obj):
        line = json.dumps(obj) + NL
        self.proc.stdin.write(line.encode())
        self.proc.stdin.flush()

    def _recv(self, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if select.select([self.proc.stdout], [], [], 0.1)[0]:
                chunk = os.read(self.proc.stdout.fileno(), 1 << 16)
                if chunk:
                    self.buf += chunk
            text = self.buf.decode(errors="replace")
            while NL in text:
                line, rest = text.split(NL, 1)
                line = line.strip()
                if not line:
                    text = rest
                    self.buf = rest.encode()
                    continue
                try:
                    obj = json.loads(line)
                    self.buf = rest.encode()
                    return obj
                except json.JSONDecodeError:
                    text = rest
                    self.buf = rest.encode()
                    continue
        return None

    def _init(self):
        self._send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "shootout", "version": "1.0"}}
        })
        self._recv()
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        time.sleep(0.5)

    def call(self, tool, args):
        self.id += 1
        self._send({
            "jsonrpc": "2.0", "id": self.id, "method": "tools/call",
            "params": {"name": tool, "arguments": args}
        })
        return self._recv()

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def codedb_count_results(resp):
    if not resp or "result" not in resp:
        return 0
    text = ""
    for item in resp["result"].get("content", []):
        if item.get("type") == "text":
            text += item["text"]
    return sum(1 for ln in text.splitlines()
               if ln.startswith("  ") and ":" in ln)


def query_codedb(client, q, iters):
    resp = client.call("codedb_search", {"query": q})
    count = codedb_count_results(resp)
    times = []
    for _ in range(iters):
        s = time.perf_counter()
        client.call("codedb_search", {"query": q})
        times.append((time.perf_counter() - s) * 1000.0)
    return times, count


def codedb_clean(corpus):
    snapshots = Path.home() / ".codedb/projects"
    if not snapshots.exists():
        return
    for d in list(snapshots.iterdir()):
        if not d.is_dir():
            continue
        for f in d.iterdir():
            try:
                content = f.read_text(errors="ignore")
                if corpus in content:
                    shutil.rmtree(d)
                    break
            except Exception:
                continue


def codedb_cold_index(bin_path, corpus):
    snapshots = Path.home() / ".codedb/projects"
    pre = {p.name for p in snapshots.iterdir()} if snapshots.exists() else set()
    s = time.perf_counter()
    # codedb argv order: [root] <command>
    subprocess.run([bin_path, corpus, "tree"], capture_output=True)
    elapsed = time.perf_counter() - s
    post = {p.name for p in snapshots.iterdir()} if snapshots.exists() else set()
    new = post - pre
    snap_dir = None
    if new:
        snap_dir = snapshots / next(iter(new))
    else:
        if snapshots.exists():
            dirs = sorted((p for p in snapshots.iterdir() if p.is_dir()),
                          key=lambda p: p.stat().st_mtime, reverse=True)
            if dirs:
                snap_dir = dirs[0]
    size = 0
    if snap_dir and snap_dir.exists():
        size = sum(f.stat().st_size for f in snap_dir.rglob("*") if f.is_file())
    return elapsed, size, snap_dir


# ---------------- lean-ctx ----------------
def leanctx_cold_index(bin_path, corpus):
    """lean-ctx index build is async; kick it off then poll status until both
    bm25 and graph indexes report finished (or stay idle long enough that we
    can be confident no build is happening)."""
    # cwd=corpus is required — lean-ctx infers project root from cwd.
    s = time.perf_counter()
    subprocess.run([bin_path, "index", "build"], capture_output=True,
                   cwd=corpus, timeout=60)
    poll_deadline = time.perf_counter() + 600
    while time.perf_counter() < poll_deadline:
        r = subprocess.run([bin_path, "index", "status"],
                           capture_output=True, text=True, cwd=corpus, timeout=30)
        try:
            j = json.loads(r.stdout)
        except Exception:
            break
        states = (j.get("graph_index", {}).get("state"),
                  j.get("bm25_index", {}).get("state"))
        running = any(st in ("running", "indexing", "in_progress")
                      for st in states if st)
        finished = all(st in ("finished", "done", "ready")
                       for st in states if st)
        if finished and not running:
            break
        if not running and time.perf_counter() - s > 8:
            # Idle for 8s — assume nothing further is happening.
            break
        time.sleep(0.5)
    elapsed = time.perf_counter() - s
    candidates = [Path.home() / ".lean-ctx",
                  Path(corpus) / ".lean-ctx"]
    size = 0
    for c in candidates:
        if c.exists():
            size += sum(f.stat().st_size for f in c.rglob("*") if f.is_file())
    return elapsed, size, 0


def query_leanctx(bin_path, q, corpus, iters):
    r = subprocess.run([bin_path, "grep", q],
                       capture_output=True, cwd=corpus, timeout=60)
    text = r.stdout.decode(errors="replace")
    m = re.search(r"(\d+)\s+matches\s+in\s+(\d+)\s+files", text)
    if m:
        out_count = int(m.group(1))
    elif "no matches" in text.lower() or text.strip() == "":
        out_count = 0
    else:
        out_count = sum(1 for ln in text.splitlines() if ":" in ln)
    times = []
    for _ in range(iters):
        s = time.perf_counter()
        subprocess.run([bin_path, "grep", q],
                       capture_output=True, cwd=corpus, timeout=60)
        times.append((time.perf_counter() - s) * 1000.0)
    return times, out_count


# ---------------- stats / report ----------------
def pct(xs, p):
    if not xs:
        return 0.0
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def write_report(out, ctx):
    lines = []
    lines.append("# search-shootout — " + ctx["corpus_name"])
    lines.append("")
    lines.append("**Date:** " + time.strftime("%Y-%m-%d %H:%M"))
    lines.append("**Corpus:** `" + ctx["corpus"] + "`")
    lines.append("**Indexed files:** " + "{:,}".format(ctx["file_count"]))
    lines.append("**Corpus bytes:** {:.1f} MB".format(ctx["corpus_bytes"] / 1e6))
    lines.append("**Iterations:** {} warm".format(ctx["iters"]))
    lines.append("")
    lines.append("## Build phase")
    lines.append("")
    lines.append("| Backend | Cold index time | On-disk size |")
    lines.append("|---|---|---|")
    for label, t, sz in ctx["builds"]:
        t_str = "{:.2f}s".format(t) if t is not None else "skipped"
        sz_str = "{:.1f} MB".format(sz / 1e6) if sz else "—"
        lines.append("| {} | {} | {} |".format(label, t_str, sz_str))
    lines.append("")
    lines.append("## Query latency (warm, ms)")
    lines.append("")
    lines.append("> codedb: MCP stdio (one server, many calls).")
    lines.append("> fts5_*: persistent SQLite connection.")
    lines.append("> lean-ctx: per-call CLI spawn (includes ~700ms binary startup).")
    lines.append("> Hit counts are NOT directly comparable across backends — use them as recall sanity (zero vs non-zero).")
    lines.append("")
    cols = ctx["backends"]
    header_parts = ["query", "kind"]
    for b in cols:
        header_parts.extend([b + " p50", b + " p99", b + " hits"])
    lines.append("| " + " | ".join(header_parts) + " |")
    lines.append("|" + "---|" * (2 + 3 * len(cols)))
    for row in ctx["rows"]:
        cells = ["`" + row["q"] + "`", row["kind"]]
        for b in cols:
            d = row["per_backend"].get(b, {})
            cells.append("{:.2f}".format(d["p50"]) if d.get("p50") is not None else "—")
            cells.append("{:.2f}".format(d["p99"]) if d.get("p99") is not None else "—")
            cells.append(str(d["hits"]) if d.get("hits") is not None else "—")
        lines.append("| " + " | ".join(cells) + " |")
    lines.append("")
    out.write_text(NL.join(lines) + NL)


# ---------------- main ----------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--iters", type=int, default=20)
    ap.add_argument("--codedb-bin", default=str(DEFAULT_CODEDB))
    ap.add_argument("--leanctx-bin", default=DEFAULT_LEANCTX or "")
    ap.add_argument("--skip-codedb", action="store_true")
    ap.add_argument("--skip-leanctx", action="store_true")
    ap.add_argument("--skip-fts5", action="store_true")
    ap.add_argument("--clean-codedb", action="store_true")
    args = ap.parse_args()

    corpus = Path(args.corpus).resolve()
    if not corpus.exists():
        print("corpus path does not exist: " + str(corpus), file=sys.stderr)
        sys.exit(1)

    queries_doc = json.loads(QUERIES_PATH.read_text())
    queries = queries_doc["queries"]

    files = list(walk_corpus(corpus))
    total_bytes = sum(p.stat().st_size for p in files)
    print("corpus: " + str(corpus))
    print("  indexable files: {:,}, bytes: {:,}".format(len(files), total_bytes))
    print("  iterations per query: {}".format(args.iters))
    print()

    builds = []
    backends = []

    fts5_tri_db = None
    fts5_uni_db = None
    if not args.skip_fts5:
        bench_dir = Path("/tmp/codedb-bench")
        bench_dir.mkdir(exist_ok=True)
        fts5_tri_db = bench_dir / "fts5_trigram.db"
        fts5_uni_db = bench_dir / "fts5_unicode61.db"

        print("[build] fts5_trigram ...", flush=True)
        t, n, sz = build_fts5(corpus, fts5_tri_db, "trigram")
        print("        {:.2f}s, {} docs, {:.1f} MB".format(t, n, sz / 1e6))
        builds.append(("fts5_trigram", t, sz))
        backends.append("fts5_tri")

        print("[build] fts5_unicode61 ...", flush=True)
        t, n, sz = build_fts5(corpus, fts5_uni_db, "unicode61")
        print("        {:.2f}s, {} docs, {:.1f} MB".format(t, n, sz / 1e6))
        builds.append(("fts5_unicode61", t, sz))
        backends.append("fts5_uni")

    codedb_client = None
    if not args.skip_codedb:
        if args.clean_codedb:
            print("[build] codedb (cleaning matching snapshot first) ...", flush=True)
            codedb_clean(str(corpus))
        else:
            print("[build] codedb ...", flush=True)
        t, sz, snap_dir = codedb_cold_index(args.codedb_bin, str(corpus))
        print("        {:.2f}s, ~{:.1f} MB ({})".format(t, sz / 1e6, snap_dir))
        builds.append(("codedb", t, sz))
        backends.append("codedb")
        codedb_client = CodedbMCP(args.codedb_bin, str(corpus))

    if not args.skip_leanctx and args.leanctx_bin:
        print("[build] lean-ctx ...", flush=True)
        try:
            t, sz, rc = leanctx_cold_index(args.leanctx_bin, str(corpus))
            print("        {:.2f}s, ~{:.1f} MB".format(t, sz / 1e6))
            builds.append(("lean-ctx", t, sz))
            backends.append("leanctx")
        except subprocess.TimeoutExpired:
            print("        TIMED OUT")
            builds.append(("lean-ctx", None, None))
    elif not args.skip_leanctx:
        print("[build] lean-ctx: binary not found, skipping")

    print()
    print("[query]")
    print("  " + " | ".join(["query"] + [b + " p50/p99 (hits)" for b in backends]))

    rows = []
    for qd in queries:
        q = qd["q"]
        kind = qd["kind"]
        per_backend = {}
        for b in backends:
            if b == "fts5_tri":
                times, count = query_fts5(fts5_tri_db, "trigram", q, args.iters)
            elif b == "fts5_uni":
                times, count = query_fts5(fts5_uni_db, "unicode61", q, args.iters)
            elif b == "codedb":
                times, count = query_codedb(codedb_client, q, args.iters)
            elif b == "leanctx":
                times, count = query_leanctx(args.leanctx_bin, q, str(corpus), args.iters)
            else:
                continue
            per_backend[b] = {
                "p50": pct(times, 0.5),
                "p99": pct(times, 0.99),
                "hits": count,
            }
        rows.append({"q": q, "kind": kind, "per_backend": per_backend})
        cells = ["{:<24}".format(q[:24])]
        for b in backends:
            d = per_backend[b]
            cells.append("{:>7.2f}/{:>7.2f}ms ({:>5})".format(d["p50"], d["p99"], d["hits"]))
        print("  " + " | ".join(cells))

    if codedb_client:
        codedb_client.close()

    if args.out:
        ctx = {
            "corpus": str(corpus),
            "corpus_name": corpus.name,
            "corpus_bytes": total_bytes,
            "file_count": len(files),
            "iters": args.iters,
            "backends": backends,
            "builds": builds,
            "rows": rows,
        }
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        write_report(out_path, ctx)
        print()
        print("report: " + str(out_path))


if __name__ == "__main__":
    main()
