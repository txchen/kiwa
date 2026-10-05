#!/usr/bin/env python3
"""CPU, memory, and outer-byte benchmark: Kiwa against an isolated tmux.

Each multiplexer runs at 100x40 with `/bin/sh` in every pane. An attached
scenario runs the client in a PTY that this script drains; a detached one
sets the session up through a client, detaches it, and measures the server
alone. Per scenario and run, it reports the server's and the client's CPU
(utime + stime from /proc/<pid>/stat), their context switches, their VmRSS
at the end of the sample, and the bytes read from the outer PTY during the
sample. Producer programs run inside panes and are not counted.

Kiwa's tabs and tmux's windows have the same structure: one pane each, the
last one focused. Kiwa runs against an outer side that answers its attach
probes like a terminal with left and right margins (DECLRMM); in the
scrolling scenario it also runs against one without them. tmux's queries
go unanswered.

Kiwa uses a private KIWA_SOCKET and KIWA_STATE_DIR. tmux runs only as
`tmux -L kiwa-bench-<pid>-<n> -f /dev/null`, and only that socket is
killed at the end, so the user's tmux and Kiwa servers are never touched.

Usage: tools/bench.py KIWA_BINARY [--build MODE] [--runs N] [--warmup S] [--sample S]
Usually run through `zig build bench -Doptimize=ReleaseFast`.
"""

import argparse
import fcntl
import os
import select
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
from dataclasses import dataclass

COLS, ROWS = 100, 40
CLK_TCK = os.sysconf("SC_CLK_TCK")
PREFIX = b"\x02"

SPINNER = """\
import sys, time
chars = "|/-\\\\"
i = 0
t = time.monotonic()
while True:
    sys.stdout.write("\\r" + chars[i % 4])
    sys.stdout.flush()
    i += 1
    t += 1 / 60
    time.sleep(max(0.0, t - time.monotonic()))
"""

PRODUCER = """\
import sys, time
words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor "
i = 0
t = time.monotonic()
while True:
    k = i % len(words)
    sys.stdout.write("%08d " % i + (words[k:] + words)[:70] + "\\n")
    sys.stdout.flush()
    i += 1
    t += 1 / 30
    time.sleep(max(0.0, t - time.monotonic()))
"""

# Script text and the bytes per second it writes to its pane.
SCRIPTS = {
    "spinner.py": (SPINNER, 60 * 2),
    "producer.py": (PRODUCER, 30 * 80),
}


@dataclass(frozen=True)
class Scenario:
    name: str
    tabs: int = 1
    # The script the focused (last) tab runs.
    focused: str | None = None
    # Every tab but the focused one runs the producer.
    hidden: bool = False
    attached: bool = True
    # Frames per second the focused script draws.
    fps: int = 0
    # Also run Kiwa against an outer side without left and right margins.
    plain: bool = False

    def scripts(self):
        hidden = ["producer.py"] * (self.tabs - 1) if self.hidden else []
        return sorted(hidden + ([self.focused] if self.focused else []))


SCENARIOS = [
    Scenario("1 idle pane"),
    Scenario("60 Hz one-cell spinner", focused="spinner.py", fps=60),
    Scenario("30 lines/s of 80 bytes", focused="producer.py", fps=30, plain=True),
    Scenario("10 idle panes", tabs=10),
    Scenario("1 idle pane, detached", attached=False),
    Scenario("10 idle panes, detached", tabs=10, attached=False),
    Scenario("10 hidden producers, focused pane idle", tabs=11, hidden=True),
    Scenario("10 hidden producers, detached", tabs=11, hidden=True, attached=False),
]

DECRQM_MARGINS = b"\x1b[?69$p"
DA1 = b"\x1b[c"


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        stat = f.read()
    fields = stat[stat.rindex(")") + 2 :].split()
    # fields[0] is field 3 (state); utime and stime are fields 14 and 15.
    return int(fields[11]) + int(fields[12])


def status_field(pid, *names):
    total = 0
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.split(":")[0] in names:
                total += int(line.split()[1])
    return total


def context_switches(pid):
    return status_field(pid, "voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")


def rss_kib(pid):
    return status_field(pid, "VmRSS")


def bytes_written(pid):
    with open(f"/proc/{pid}/io") as f:
        for line in f:
            if line.startswith("wchar:"):
                return int(line.split()[1])
    raise RuntimeError(f"no wchar for {pid}")


def script_pids(work):
    """Maps each running bench script under `work` to its pids."""
    found = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        for name in SCRIPTS:
            if os.path.join(work, name).encode() in argv:
                found.setdefault(name, []).append(int(entry))
    return found


def strays(work):
    """Pids of processes that still run in `work` or name it on their command line."""
    pids = []
    want = work.encode()
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == os.getpid():
            continue
        try:
            cwd = os.readlink(f"/proc/{entry}/cwd")
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                cmdline = f.read()
        except OSError:
            continue
        if cwd == work or cwd.startswith(work + "/") or want in cmdline:
            pids.append(int(entry))
    return pids


def reap_strays(work):
    for _ in range(60):
        if not strays(work):
            return
        time.sleep(0.05)
    left = strays(work)
    for pid in left:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if left:
        print(f"  warning: killed stray processes {left} of {work}", flush=True)


class Outer:
    """The outer terminal. With `margins` set to True or False, it answers
    DECRQM for mode 69 and DA1 like a terminal with or without left and
    right margins; with None it answers nothing."""

    def __init__(self, argv, env, cwd, margins=None):
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        pid = os.fork()
        if pid == 0:
            os.close(master)
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            for fd in (0, 1, 2):
                os.dup2(slave, fd)
            os.close(slave)
            os.chdir(cwd)
            os.execve(argv[0], argv, env)
        os.close(slave)
        self.fd = master
        self.pid = pid
        self.reaped = False
        self.bytes = 0
        self.tail = b""
        self.margins = margins

    def pump(self, seconds):
        end = time.monotonic() + seconds
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return
            ready, _, _ = select.select([self.fd], [], [], left)
            if not ready:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            self.bytes += len(data)
            self.tail = (self.tail + data)[-65536:]
            if self.margins is not None:
                self.answer(self.tail[-(len(data) + len(DECRQM_MARGINS)):], len(data))

    def answer(self, window, fresh):
        """Answers each query that ends in the last `fresh` bytes of `window`."""
        found = []
        for query in (DECRQM_MARGINS, DA1):
            at = window.find(query, max(0, len(window) - fresh - len(query) + 1))
            while at >= 0:
                found.append((at, query))
                at = window.find(query, at + 1)
        for _, query in sorted(found):
            if query == DA1:
                self.send(b"\x1b[?62;22c")
            else:
                self.send(b"\x1b[?69;%d$y" % (2 if self.margins else 0))

    def wait_for(self, needle, seconds=10):
        end = time.monotonic() + seconds
        while needle not in self.tail:
            if time.monotonic() > end:
                raise RuntimeError(f"timed out waiting for {needle!r}")
            self.pump(0.05)

    def wait_exit(self, seconds=10):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self.pump(0.05)
            if os.waitpid(self.pid, os.WNOHANG)[0] == self.pid:
                self.reaped = True
                return
        raise RuntimeError("the client did not exit")

    def send(self, data):
        os.write(self.fd, data)

    def close(self):
        if not self.reaped:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(self.pid, 0)
        os.close(self.fd)


def base_env(home):
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": home,
        "SHELL": "/bin/sh",
        "PS1": "$ ",
        "TERM": "xterm-256color",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
    }


def command(work, script):
    return f"python3 {os.path.join(work, script)}"


class Kiwa:
    """Sets the scenario up through the attached client's keys: `ctrl+b c`
    for each further tab, `ctrl+b q` to detach."""

    def __init__(self, binary, work, scenario, margins):
        self.binary = binary
        self.env = base_env(work)
        self.env["KIWA_SOCKET"] = os.path.join(work, "kiwa.sock")
        self.env["KIWA_STATE_DIR"] = os.path.join(work, "state")
        self.work = work
        self.server = None
        self.outer = Outer([binary], self.env, work, margins)
        # On failure the caller deletes the work directory and the socket
        # in it, so the server must stop here.
        try:
            self.outer.wait_for(b"$")
            self.server = self.find_server()
            for i in range(scenario.tabs):
                if i > 0:
                    self.new_tab(i + 1)
                if scenario.hidden and i < scenario.tabs - 1:
                    self.outer.send(command(work, "producer.py").encode() + b"\r")
            if scenario.focused:
                self.outer.send(command(work, scenario.focused).encode() + b"\r")
            if not scenario.attached:
                self.outer.pump(0.5)
                self.outer.send(PREFIX + b"q")
                self.outer.wait_exit()
        except BaseException:
            self.stop()
            raise
        self.client = self.outer.pid if scenario.attached else None

    def new_tab(self, count):
        self.outer.tail = b""
        self.outer.send(PREFIX + b"c")
        self.outer.wait_for(b"$")
        end = time.monotonic() + 10
        while self.tab_count() != count:
            if time.monotonic() > end:
                raise RuntimeError(f"tab {count} never opened")
            self.outer.pump(0.05)

    def tab_count(self):
        listing = subprocess.run([self.binary, "ls"], env=self.env, timeout=10, check=True,
                                 capture_output=True, text=True).stdout
        return sum(1 for line in listing.splitlines() if line.startswith("  "))

    def find_server(self):
        want = f"KIWA_SOCKET={self.env['KIWA_SOCKET']}\0".encode()
        for _ in range(100):
            for entry in os.listdir("/proc"):
                if not entry.isdigit():
                    continue
                try:
                    with open(f"/proc/{entry}/cmdline", "rb") as f:
                        if b"__server" not in f.read():
                            continue
                    with open(f"/proc/{entry}/environ", "rb") as f:
                        if want in f.read():
                            return int(entry)
                except OSError:
                    continue
            time.sleep(0.05)
        raise RuntimeError("kiwa server not found")

    def stop(self):
        subprocess.run([self.binary, "kill-server"], env=self.env, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.outer.close()
        if self.server is None:
            return
        for _ in range(100):
            if not os.path.exists(f"/proc/{self.server}"):
                return
            time.sleep(0.05)
        os.kill(self.server, signal.SIGKILL)


class Tmux:
    """Sets the scenario up with tmux commands: one window per Kiwa tab,
    the last one current, and attaches only an attached scenario."""

    count = 0

    def __init__(self, binary, work, scenario):
        Tmux.count += 1
        self.binary = binary
        self.socket = f"kiwa-bench-{os.getpid()}-{Tmux.count}"
        self.socket_path = None
        self.env = base_env(work)
        self.base = [binary, "-L", self.socket, "-f", "/dev/null"]
        self.outer = None
        try:
            # The status line is off so both multiplexers show a 100x40 pane.
            self.run("new-session", "-d", "-x", str(COLS), "-y", str(ROWS), "-c", work, "/bin/sh",
                     ";", "set", "-g", "status", "off")
            pid, self.socket_path = self.run("display-message", "-p", "#{pid} #{socket_path}").split()
            self.server = int(pid)
            for _ in range(scenario.tabs - 1):
                self.run("new-window", "-c", work, "/bin/sh")
            if scenario.hidden:
                for i in range(scenario.tabs - 1):
                    self.run("send-keys", "-t", f":{i}", command(work, "producer.py"), "Enter")
            if scenario.attached:
                self.outer = Outer(self.base + ["attach-session"], self.env, work)
                self.outer.wait_for(b"$")
            if scenario.focused:
                if self.outer:
                    self.outer.send(command(work, scenario.focused).encode() + b"\r")
                else:
                    self.run("send-keys", command(work, scenario.focused), "Enter")
        except BaseException:
            self.stop()
            raise
        self.client = self.outer.pid if self.outer else None

    def run(self, *args):
        return subprocess.run(self.base + list(args), env=self.env, check=True, timeout=10,
                              capture_output=True, text=True).stdout

    def tab_count(self):
        return len(self.run("list-windows", "-F", "#{window_index}").split())

    def stop(self):
        subprocess.run(self.base + ["kill-server"], env=self.env, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if self.outer:
            self.outer.close()
        # tmux leaves its socket file behind after kill-server.
        if self.socket_path and os.path.basename(self.socket_path) == self.socket:
            try:
                os.unlink(self.socket_path)
            except FileNotFoundError:
                pass


def wait(v, seconds):
    if v.outer and v.client:
        v.outer.pump(seconds)
    else:
        time.sleep(seconds)


def measure(name, start, scenario, warmup, sample):
    work = tempfile.mkdtemp(prefix=f"kiwa-bench-{name}-")
    for script, (text, _) in SCRIPTS.items():
        with open(os.path.join(work, script), "w") as f:
            f.write(text)
    v = None
    try:
        v = start(work, scenario)
        wait(v, warmup)
        roles = {"server": v.server, "client": v.client}
        pids = [p for p in roles.values() if p]
        scripts = script_pids(work)
        written = {p: bytes_written(p) for ps in scripts.values() for p in ps}
        ticks = {role: cpu_ticks(p) for role, p in roles.items() if p}
        switches = sum(context_switches(p) for p in pids)
        if v.outer:
            v.outer.bytes = 0
            v.outer.tail = b""
        began = time.monotonic()
        wait(v, sample)
        elapsed = time.monotonic() - began
        ticks = {role: cpu_ticks(p) - ticks[role] for role, p in roles.items() if p}
        switches = sum(context_switches(p) for p in pids) - switches
        rss = {role: rss_kib(p) for role, p in roles.items() if p}
        return {
            "elapsed": elapsed,
            "ticks": sum(ticks.values()),
            "cpu": {role: 100.0 * t / CLK_TCK / elapsed for role, t in ticks.items()},
            "total": 100.0 * sum(ticks.values()) / CLK_TCK / elapsed,
            "switches": switches,
            "rss": rss,
            "bytes": v.outer.bytes if v.client else None,
            "tail": v.outer.tail if v.client else b"",
            "tabs": v.tab_count(),
            "scripts": {script: [bytes_written(p) - written[p] for p in ps] for script, ps in scripts.items()},
            "load": os.getloadavg()[0],
        }
    finally:
        if v is not None:
            v.stop()
        reap_strays(work)
        shutil.rmtree(work, ignore_errors=True)


def check_work(scenario, variant, result):
    """Fails a run whose panes did not do the scenario's work, or whose Kiwa
    scrolled other than its outer side's margins allow."""
    name = scenario.name
    if result["tabs"] != scenario.tabs:
        raise RuntimeError(f"{name}: {variant} had {result['tabs']} tabs, not {scenario.tabs}")
    running = sorted(s for s, ws in result["scripts"].items() for _ in ws)
    if running != scenario.scripts():
        raise RuntimeError(f"{name}: {variant} ran {running}, not {scenario.scripts()}")
    for script, ws in result["scripts"].items():
        want = SCRIPTS[script][1] * result["elapsed"]
        if min(ws) < 0.9 * want:
            raise RuntimeError(f"{name}: {variant}: a {script} wrote {min(ws)} of {want:.0f} bytes")
    if not scenario.attached:
        return
    tail = result["tail"]
    if scenario.focused == "spinner.py" and result["bytes"] == 0:
        raise RuntimeError(f"{name}: the spinner produced no outer bytes")
    if scenario.hidden and b"lorem" in tail:
        raise RuntimeError(f"{name}: {variant} drew a hidden producer's lines")
    if scenario.focused == "producer.py":
        if b"lorem" not in tail:
            raise RuntimeError(f"{name}: producer lines never reached the outer terminal")
        if variant.startswith("kiwa") and b"S\x1b[r" not in tail:
            raise RuntimeError(f"{name}: {variant} never scrolled the outer terminal")
        used = b"\x1b[?69h" in tail
        if variant.startswith("kiwa") and used != (variant == "kiwa-margins"):
            raise RuntimeError(f"{name}: {variant} {'used' if used else 'never used'} left and right margins")


def summarize(values, fmt):
    med = statistics.median(values)
    if min(values) == max(values):
        return fmt(med)
    return f"{fmt(med)} ({fmt(min(values))} to {fmt(max(values))})"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("kiwa")
    ap.add_argument("--build", default="unknown", help="Kiwa's optimize mode, for the report")
    ap.add_argument("--tmux", default=shutil.which("tmux") or "tmux")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--warmup", type=float, default=6.0)
    ap.add_argument("--sample", type=float, default=12.0)
    ap.add_argument("--only", help="run only the scenarios whose name contains this text")
    args = ap.parse_args()
    kiwa = os.path.abspath(args.kiwa)
    scenarios = [s for s in SCENARIOS if not args.only or args.only in s.name]

    tmux_version = subprocess.run([args.tmux, "-V"], capture_output=True, text=True).stdout.strip()
    kiwa_version = subprocess.run([kiwa, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"{kiwa_version}, build {args.build}; {tmux_version}", flush=True)
    print(f"{COLS}x{ROWS}, warmup {args.warmup:g} s, sample {args.sample:g} s, {args.runs} runs, "
          f"load {os.getloadavg()[0]:.2f}, {os.cpu_count()} CPUs", flush=True)
    tick_pct = 100.0 / CLK_TCK / args.sample
    print(f"tick resolution: 1 tick = {1000 / CLK_TCK:g} ms = {tick_pct:.3f}% of one core over the sample",
          flush=True)

    variants = {
        "kiwa-margins": (f"Kiwa ({args.build}), outer with margins",
                         lambda work, s: Kiwa(kiwa, work, s, True)),
        "kiwa-plain": (f"Kiwa ({args.build}), outer without margins",
                       lambda work, s: Kiwa(kiwa, work, s, False)),
        "tmux": (tmux_version, lambda work, s: Tmux(args.tmux, work, s)),
    }
    results = {}
    for scenario in scenarios:
        names = [n for n in variants if n != "kiwa-plain" or scenario.plain]
        for run in range(args.runs):
            # Rotating keeps drift and warm caches from favoring one side.
            order = names[run % len(names):] + names[:run % len(names)]
            for name in order:
                r = measure(name, variants[name][1], scenario, args.warmup, args.sample)
                check_work(scenario, name, r)
                results.setdefault((scenario.name, name), []).append(r)
                cpu = ", ".join(f"{role} {pct:.3f}%" for role, pct in r["cpu"].items())
                rss = ", ".join(f"{role} {kib} KiB" for role, kib in r["rss"].items())
                print(f"  {scenario.name} run {run + 1} {name}: {r['ticks']} ticks, {cpu}, "
                      f"{r['bytes']} bytes, {r['switches']} context switches, RSS {rss}, "
                      f"load {r['load']:.2f}", flush=True)

    print()
    print(f"load at the end {' '.join(f'{v:.2f}' for v in os.getloadavg())}")
    print()
    print("| Scenario | Variant | Server CPU % | Client CPU % | Total CPU % of one core, median (range) "
          f"| Ticks per run | Context switches | Outer bytes in {args.sample:g} s | Outer bytes per frame "
          "| Server RSS MiB | Client RSS MiB |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    pct = lambda v: f"{v:.2f}"
    count = lambda v: f"{v:,.0f}"
    mib = lambda v: f"{v / 1024:.1f}"
    for scenario in scenarios:
        frames = scenario.fps * args.sample
        for name, (label, _) in variants.items():
            rs = results.get((scenario.name, name))
            if not rs:
                continue
            attached = rs[0]["bytes"] is not None

            def column(get, fmt, rs=rs):
                values = [get(r) for r in rs]
                return "-" if None in values else summarize(values, fmt)

            per_frame = (f"{statistics.median(r['bytes'] for r in rs) / frames:,.1f}"
                         if attached and frames else "-")
            print(f"| {scenario.name} | {label} "
                  f"| {column(lambda r: r['cpu']['server'], pct)} "
                  f"| {column(lambda r: r['cpu'].get('client'), pct)} "
                  f"| {column(lambda r: r['total'], pct)} "
                  f"| {', '.join(str(r['ticks']) for r in rs)} "
                  f"| {column(lambda r: r['switches'], count)} "
                  f"| {column(lambda r: r['bytes'], count)} "
                  f"| {per_frame} "
                  f"| {column(lambda r: r['rss']['server'], mib)} "
                  f"| {column(lambda r: r['rss'].get('client'), mib)} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
