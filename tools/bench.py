#!/usr/bin/env python3
"""CPU, memory, and outer-byte benchmark: Kiwa against tmux.

PROGRAMS lists the multiplexers. Each runs every scenario at 100x40 with
`/bin/sh` in every pane, in its default UI except that tmux's status line is
off. A Kiwa tab is a tmux window; each holds one pane, and the last one is
focused. An attached scenario runs the client in a PTY that this script
drains; a detached one sets the session up through a client, detaches it,
and measures what stays.

Per scenario and run, the bench reports CPU (run time from
/proc/<pid>/task/*/schedstat, plus utime + stime ticks from /proc/<pid>/stat
for comparison with older tables), context switches, VmRSS at the end of the
sample, and the bytes read from the outer PTY during the sample. Each count
sums the program's own processes: those whose /proc/<pid>/exe is the
program's binary and that are tied to the run's work directory. The process
in the outer PTY is the client, and every other one counts as the server.
Producer programs run inside panes and are not counted.

Kiwa runs against an outer side that answers its attach probes like a
terminal with left and right margins (DECLRMM); in the scrolling scenario it
also runs against one without them. tmux's queries go unanswered.

Every program runs with a private HOME, XDG directories, config, and socket
under the run's work directory, so the user's own sessions are never
contacted. tmux runs only as `tmux -L kiwa-bench-<pid>-<n> -f /dev/null`.
SIGTERM and SIGHUP unwind like ctrl+c, so an interrupted run still stops its
servers and removes their sockets.

After the results table comes a table of each program's processes. With
--check, the v1 budgets in GATES are checked against the medians after the
tables, and the exit status is 1 if Kiwa misses any of them.

Usage: tools/bench.py KIWA_BINARY [--build MODE] [--programs LIST] [--runs N]
       [--warmup S] [--sample S] [--only TEXT] [--check]
Usually run through `zig build bench -Doptimize=ReleaseFast`, or
`zig build bench-check -Doptimize=ReleaseFast` for --check.
"""

import argparse
import fcntl
import os
import platform
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
from collections.abc import Callable
from dataclasses import dataclass, field

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

# A relative CPU gate allows this share of tmux's median, but at least
# MIN_TOLERANCE percentage points, for measurement noise.
TOLERANCE = 0.05
MIN_TOLERANCE = 0.01


def median(runs, get):
    return statistics.median(get(r) for r in runs)


def idle_budget(kiwa, tmux):
    """Idle is a hard rule, so every run must be zero, not only the median."""
    cpu = max(r["total"] for r in kiwa)
    switches = max(sum(r["switches"].values()) for r in kiwa)
    return (cpu == 0 and switches == 0,
            f"Kiwa worst run {cpu:.3f}% CPU and {switches:g} context switches, limit 0 and 0")


def cpu_budget(factor):
    """Kiwa's total CPU at most `factor` times tmux's, plus the tolerance."""
    def check(kiwa, tmux):
        k = median(kiwa, lambda r: r["total"])
        t = median(tmux, lambda r: r["total"])
        tolerance = max(TOLERANCE * t, MIN_TOLERANCE)
        limit = factor * t + tolerance
        return (k <= limit, f"Kiwa {k:.3f}%, tmux {t:.3f}%, "
                f"limit {factor:g} x tmux + {tolerance:.3f} = {limit:.3f}%")
    return check


def rss_budget(mib):
    def check(kiwa, tmux):
        rss = median(kiwa, lambda r: r["rss"]["server"]) / 1024
        return rss <= mib, f"Kiwa server RSS {rss:.1f} MiB, limit {mib:g} MiB"
    return check


# The v1 budgets: name, the scenarios each covers, and its check against
# every Kiwa variant of a scenario.
GATES = [
    ("Idle", lambda s: not s.focused and not s.hidden, idle_budget),
    ("Spinner", lambda s: s.focused == "spinner.py", cpu_budget(1.0)),
    ("Hidden output", lambda s: s.hidden, cpu_budget(1.0)),
    ("Scrolling", lambda s: s.focused == "producer.py", cpu_budget(1.5)),
    ("Memory", lambda s: s.tabs >= 10, rss_budget(20)),
]

DECRQM_MARGINS = b"\x1b[?69$p"
DA1 = b"\x1b[c"


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        stat = f.read()
    fields = stat[stat.rindex(")") + 2 :].split()
    # fields[0] is field 3 (state); utime and stime are fields 14 and 15.
    return int(fields[11]) + int(fields[12])


def run_ns(pid):
    """CPU time of all of `pid`'s threads, in nanoseconds."""
    total = 0
    for task in os.listdir(f"/proc/{pid}/task"):
        with open(f"/proc/{pid}/task/{task}/schedstat") as f:
            total += int(f.read().split()[0])
    return total


def status_field(path, *names):
    total = 0
    with open(path) as f:
        for line in f:
            if line.split(":")[0] in names:
                total += int(line.split()[1])
    return total


def context_switches(pid):
    """Context switches of all of `pid`'s threads; /proc/<pid>/status
    counts only the main thread's."""
    return sum(status_field(f"/proc/{pid}/task/{task}/status",
                            "voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")
               for task in os.listdir(f"/proc/{pid}/task"))


def rss_kib(pid):
    return status_field(f"/proc/{pid}/status", "VmRSS")


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
    """Pids of processes that still run in `work` or name it on their command
    line or in their environment. The Kiwa server runs in `/`, so only its
    KIWA_SOCKET ties it to `work`."""
    pids = []
    want = work.encode()
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == os.getpid():
            continue
        try:
            cwd = os.readlink(f"/proc/{entry}/cwd")
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                cmdline = f.read()
            with open(f"/proc/{entry}/environ", "rb") as f:
                environ = f.read()
        except OSError:
            continue
        if cwd == work or cwd.startswith(work + "/") or want in cmdline or want in environ:
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
            try:
                os.close(master)
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                os.close(slave)
                os.chdir(cwd)
                os.execve(argv[0], argv, env)
            finally:
                os._exit(127)
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


def private_env(work):
    """The environment of every program and CLI call in a run: HOME and every
    XDG directory under `work`."""
    env = base_env(work)
    for name, folder in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                         ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache"),
                         ("XDG_RUNTIME_DIR", "runtime")):
        env[name] = os.path.join(work, folder)
        os.makedirs(env[name], mode=0o700, exist_ok=True)
    return env


def describe(pid, work):
    with open(f"/proc/{pid}/cmdline", "rb") as f:
        argv = f.read().rstrip(b"\0").decode(errors="replace").split("\0")
    text = " ".join([os.path.basename(argv[0])] + argv[1:]).replace(work, "<work>")
    return text if len(text) <= 72 else text[:69] + "..."


class Driver:
    """What every driver shares: a private environment, the set of the
    program's own processes, and stopping all of them. `outer` is the
    attached client's PTY, or None when no client is attached."""

    def __init__(self, binary, work):
        self.binary = binary
        self.exe = os.path.realpath(binary)
        self.work = work
        self.env = private_env(work)
        self.outer = None

    def cli(self, *argv):
        return subprocess.run(argv, env=self.env, cwd=self.work, check=True, timeout=10,
                              capture_output=True, text=True).stdout

    def cli_quietly(self, *argv):
        subprocess.run(argv, env=self.env, cwd=self.work, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def processes(self):
        """Maps each running process of the program in this run to its role:
        "client" for the one in the outer PTY, "server" for every other."""
        client = self.outer.pid if self.outer else None
        found = {}
        for pid in strays(self.work):
            try:
                if os.readlink(f"/proc/{pid}/exe") != self.exe:
                    continue
            except OSError:
                continue
            found[pid] = "client" if pid == client else "server"
        return found

    def shut_down(self):
        """Asks the program to stop through its own command."""

    def stop(self):
        try:
            self.shut_down()
        finally:
            if self.outer:
                self.outer.close()
                self.outer = None
            end = time.monotonic() + 5
            while (left := self.processes()) and time.monotonic() < end:
                time.sleep(0.05)
            for pid in left:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


class ThroughClient(Driver):
    """Sets the scenario up through an attached client, as a user would: one
    further tab at a time, a producer typed into each hidden tab, and the
    focused script typed into the last one. A detached scenario then
    detaches the client. Subclasses start the client and open, count, and
    detach tabs in their program's own way."""

    def __init__(self, binary, work, scenario, margins=None):
        super().__init__(binary, work)
        self.outer = Outer(self.client(), self.env, work, margins)
        # On failure the caller deletes the work directory and the socket
        # in it, so the program must stop here.
        try:
            self.wait_for_prompt()
            for i in range(scenario.tabs):
                if i > 0:
                    self.open_tab(i + 1)
                if scenario.hidden and i < scenario.tabs - 1:
                    self.type(command(work, "producer.py"))
            if scenario.focused:
                self.type(command(work, scenario.focused))
            if not scenario.attached:
                self.outer.pump(0.5)
                self.detach()
                self.outer.wait_exit()
                self.outer.close()
                self.outer = None
        except BaseException:
            self.stop()
            raise

    def wait_for_prompt(self):
        self.outer.wait_for(b"$")

    def type(self, text):
        self.outer.send(text.encode() + b"\r")

    def open_tab(self, count):
        self.outer.tail = b""
        self.new_tab()
        self.wait_for_prompt()
        end = time.monotonic() + 10
        while self.tab_count() != count:
            if time.monotonic() > end:
                raise RuntimeError(f"tab {count} never opened")
            self.outer.pump(0.05)


class Kiwa(ThroughClient):
    """Kiwa with a private KIWA_SOCKET and KIWA_STATE_DIR. `ctrl+b c` opens
    a tab and `ctrl+b q` detaches."""

    def client(self):
        self.env["KIWA_SOCKET"] = os.path.join(self.work, "kiwa.sock")
        self.env["KIWA_STATE_DIR"] = os.path.join(self.work, "state")
        return [self.binary]

    def new_tab(self):
        self.outer.send(PREFIX + b"c")

    def detach(self):
        self.outer.send(PREFIX + b"q")

    def tab_count(self):
        listing = self.cli(self.binary, "ls")
        return sum(1 for line in listing.splitlines() if line.startswith("  "))

    def shut_down(self):
        self.cli_quietly(self.binary, "kill-server")


class Tmux(Driver):
    """Sets the scenario up with tmux commands: one window per Kiwa tab,
    the last one current, and attaches only an attached scenario. The
    status line is off, so the pane is 100x40 as in ticket 11's tables."""

    count = 0

    def __init__(self, binary, work, scenario):
        super().__init__(binary, work)
        Tmux.count += 1
        self.socket = f"kiwa-bench-{os.getpid()}-{Tmux.count}"
        self.env["TMUX_TMPDIR"] = work
        self.socket_path = os.path.join(work, f"tmux-{os.getuid()}", self.socket)
        self.base = [binary, "-L", self.socket, "-f", "/dev/null"]
        try:
            self.run("new-session", "-d", "-x", str(COLS), "-y", str(ROWS), "-c", work, "/bin/sh",
                     ";", "set", "-g", "status", "off")
            socket_path = self.run("display-message", "-p", "#{socket_path}").strip()
            if socket_path != self.socket_path:
                raise RuntimeError(f"tmux socket at {socket_path}, not {self.socket_path}")
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

    def run(self, *args):
        return self.cli(*self.base, *args)

    def tab_count(self):
        return len(self.run("list-windows", "-F", "#{window_index}").split())

    def shut_down(self):
        self.cli_quietly(*self.base, "kill-server")


@dataclass(frozen=True)
class Variant:
    name: str
    # Appended to the program's label in the tables.
    suffix: str = ""
    options: dict = field(default_factory=dict)
    covers: Callable[[Scenario], bool] = lambda scenario: True


@dataclass(frozen=True)
class Program:
    name: str
    # The binary to run; None when this machine has none.
    binary: Callable[[argparse.Namespace], str | None]
    # The flag that prints the binary's version.
    version_flag: str
    driver: type
    variants: tuple[Variant, ...]
    label: Callable[[str, argparse.Namespace], str] = lambda version, args: version


PROGRAMS = [
    Program("kiwa", lambda args: os.path.abspath(args.kiwa), "--version", Kiwa,
            (Variant("kiwa-margins", ", outer with margins", {"margins": True}),
             Variant("kiwa-plain", ", outer without margins", {"margins": False},
                     lambda scenario: scenario.plain)),
            lambda version, args: f"Kiwa ({args.build})"),
    Program("tmux", lambda args: args.tmux or shutil.which("tmux"), "-V", Tmux,
            (Variant("tmux"),)),
]

def wait(v, seconds):
    if v.outer:
        v.outer.pump(seconds)
    else:
        time.sleep(seconds)


def usage(pid):
    return cpu_ticks(pid), run_ns(pid), context_switches(pid)


def measure(name, start, scenario, warmup, sample):
    work = tempfile.mkdtemp(prefix=f"kiwa-bench-{name}-")
    for script, (text, _) in SCRIPTS.items():
        with open(os.path.join(work, script), "w") as f:
            f.write(text)
    v = None
    try:
        v = start(work, scenario)
        wait(v, warmup)
        # Read at the start of the sample, so helpers started late count.
        roles = v.processes()
        if "server" not in roles.values():
            raise RuntimeError(f"{scenario.name}: {name} has no server process")
        commands = sorted((role, describe(pid, work)) for pid, role in roles.items())
        scripts = script_pids(work)
        written = {p: bytes_written(p) for ps in scripts.values() for p in ps}
        before = {pid: usage(pid) for pid in roles}
        if v.outer:
            v.outer.bytes = 0
            v.outer.tail = b""
        began = time.monotonic()
        wait(v, sample)
        elapsed = time.monotonic() - began
        try:
            after = {pid: usage(pid) for pid in roles}
            rss = {pid: rss_kib(pid) for pid in roles}
        except FileNotFoundError as e:
            raise RuntimeError(f"{scenario.name}: a {name} process exited during the sample") from e

        def per_role(get):
            sums = {role: 0 for role in ("server", "client") if role in roles.values()}
            for pid, role in roles.items():
                sums[role] += get(pid)
            return sums

        ns = per_role(lambda pid: after[pid][1] - before[pid][1])
        return {
            "elapsed": elapsed,
            "ticks": sum(after[pid][0] - before[pid][0] for pid in roles),
            "cpu": {role: 100.0 * t / 1e9 / elapsed for role, t in ns.items()},
            "total": 100.0 * sum(ns.values()) / 1e9 / elapsed,
            "switches": per_role(lambda pid: after[pid][2] - before[pid][2]),
            "rss": per_role(lambda pid: rss[pid]),
            "processes": commands,
            "bytes": v.outer.bytes if v.outer else None,
            "tail": v.outer.tail if v.outer else b"",
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


def print_results(scenarios, variants, results, sample):
    print("| Scenario | Variant | Server CPU % | Client CPU % | Total CPU % of one core, median (range) "
          f"| Ticks per run | Context switches | Outer bytes in {sample:g} s | Outer bytes per frame "
          "| Server RSS MiB | Client RSS MiB |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    pct = lambda v: f"{v:.3f}"
    count = lambda v: f"{v:,.0f}"
    mib = lambda v: f"{v / 1024:.1f}"
    for scenario in scenarios:
        frames = scenario.fps * sample
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
                  f"| {column(lambda r: sum(r['switches'].values()), count)} "
                  f"| {column(lambda r: r['bytes'], count)} "
                  f"| {per_frame} "
                  f"| {column(lambda r: r['rss']['server'], mib)} "
                  f"| {column(lambda r: r['rss'].get('client'), mib)} |")


def print_processes(programs, results):
    """One row per program: the processes counted in an attached and in a
    detached run, with the most of each role seen in one run."""
    print("| Program | Attached runs | Detached runs |")
    print("|---|---|---|")
    for program, _, label, _ in programs:
        names = {variant.name for variant in program.variants}
        cells = []
        for attached in (True, False):
            runs = [r for (_, name), rs in results.items() if name in names
                    for r in rs if (r["bytes"] is not None) == attached]
            roles = {}
            for r in runs:
                for role in ("server", "client"):
                    commands = [c for rl, c in r["processes"] if rl == role]
                    most, _ = roles.get(role, (0, None))
                    if len(commands) > most:
                        roles[role] = (len(commands), commands)
            cells.append("; ".join(f"{role} x{n}: " + ", ".join(f"`{c}`" for c in commands)
                                   for role, (n, commands) in sorted(roles.items(), reverse=True)) or "-")
        print(f"| {label} | {cells[0]} | {cells[1]} |")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("kiwa")
    ap.add_argument("--build", default="unknown", help="Kiwa's optimize mode, for the report")
    ap.add_argument("--tmux", help="tmux binary (default: tmux on PATH)")
    ap.add_argument("--programs", default=",".join(p.name for p in PROGRAMS),
                    help="comma-separated programs to run (default: all)")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--warmup", type=float, default=6.0)
    ap.add_argument("--sample", type=float, default=12.0)
    ap.add_argument("--only", help="run only the scenarios whose name contains this text")
    ap.add_argument("--check", action="store_true",
                    help="check the v1 budgets and exit 1 if Kiwa misses one")
    args = ap.parse_args()
    wanted = args.programs.split(",")
    unknown = sorted(set(wanted) - {p.name for p in PROGRAMS})
    if unknown:
        ap.error(f"unknown programs {', '.join(unknown)}; choose from {', '.join(p.name for p in PROGRAMS)}")
    if args.check and not {"kiwa", "tmux"} <= set(wanted):
        ap.error("--check compares Kiwa with tmux, so --programs must include both")
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda signum, _: sys.exit(128 + signum))
    scenarios = [s for s in SCENARIOS if not args.only or args.only in s.name]

    scratch = tempfile.mkdtemp(prefix="kiwa-bench-scratch-")
    try:
        programs = []
        for program in PROGRAMS:
            if program.name not in wanted:
                continue
            binary = program.binary(args)
            if binary is None:
                print(f"{program.name}: skipped, no binary for {platform.machine()} on this machine",
                      flush=True)
                continue
            version = subprocess.run([binary, program.version_flag], env=private_env(scratch),
                                     capture_output=True, text=True, check=True).stdout.strip()
            programs.append((program, binary, program.label(version, args), version))
        if args.check and "tmux" not in {program.name for program, *_ in programs}:
            raise RuntimeError("--check compares Kiwa with tmux, and tmux was skipped")
        return run(args, scenarios, programs, scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def run(args, scenarios, programs, scratch):
    print(f"{'; '.join(version for *_, version in programs)}; Kiwa build {args.build}", flush=True)
    print(f"{COLS}x{ROWS}, warmup {args.warmup:g} s, sample {args.sample:g} s, {args.runs} runs, "
          f"load {os.getloadavg()[0]:.2f}, {os.cpu_count()} CPUs", flush=True)
    tick_pct = 100.0 / CLK_TCK / args.sample
    print(f"tick resolution: 1 tick = {1000 / CLK_TCK:g} ms = {tick_pct:.3f}% of one core over the sample",
          flush=True)

    variants = {}
    covers = {}
    for program, binary, label, _ in programs:
        for variant in program.variants:
            start = (lambda work, s, program=program, binary=binary, variant=variant:
                     program.driver(binary, work, s, **variant.options))
            variants[variant.name] = (label + variant.suffix, start)
            covers[variant.name] = variant.covers
    results = {}
    for scenario in scenarios:
        names = [n for n in variants if covers[n](scenario)]
        for run in range(args.runs):
            # Rotating keeps drift and warm caches from favoring one side.
            order = names[run % len(names):] + names[:run % len(names)]
            for name in order:
                r = measure(name, variants[name][1], scenario, args.warmup, args.sample)
                check_work(scenario, name, r)
                results.setdefault((scenario.name, name), []).append(r)
                cpu = ", ".join(f"{role} {pct:.3f}%" for role, pct in r["cpu"].items())
                rss = ", ".join(f"{role} {kib} KiB" for role, kib in r["rss"].items())
                switches = ", ".join(f"{role} {n}" for role, n in r["switches"].items())
                print(f"  {scenario.name} run {run + 1} {name}: {r['ticks']} ticks, {cpu}, "
                      f"{r['bytes']} bytes, context switches {switches}, RSS {rss}, "
                      f"{len(r['processes'])} processes, load {r['load']:.2f}", flush=True)

    print()
    print(f"load at the end {' '.join(f'{v:.2f}' for v in os.getloadavg())}")
    print()
    print_results(scenarios, variants, results, args.sample)
    print()
    print_processes(programs, results)
    if not args.check:
        return 0
    print()
    print(f"Gates on medians; a relative CPU gate allows {TOLERANCE:.0%} of tmux's value, "
          f"at least {MIN_TOLERANCE:g} percentage points, for noise; the idle gate allows none in any run.")
    failed = 0
    for gate, covers_gate, check in GATES:
        for scenario in filter(covers_gate, scenarios):
            tmux = results[(scenario.name, "tmux")]
            for name, (label, _) in variants.items():
                kiwa = results.get((scenario.name, name))
                if not name.startswith("kiwa") or not kiwa:
                    continue
                ok, detail = check(kiwa, tmux)
                failed += not ok
                print(f"{'PASS' if ok else 'FAIL'} {gate} | {scenario.name} | {label} | {detail}")
    print(f"{failed} gate{'' if failed == 1 else 's'} failed" if failed else "All gates passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
