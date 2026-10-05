#!/usr/bin/env python3
"""CPU and outer-byte benchmark: Kiwa against an isolated, attached tmux.

Each multiplexer runs attached in its own PTY at 100x40 while this script
drains that PTY. Per scenario and run, it reports server plus client CPU
(utime + stime from /proc/<pid>/stat) and the bytes read from the outer PTY
during the sample window. Producer programs run inside the pane and are not
counted.

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

COLS, ROWS = 100, 40
CLK_TCK = os.sysconf("SC_CLK_TCK")

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

SCENARIOS = [
    ("1 idle pane", None),
    ("60 Hz one-cell spinner", "spinner.py"),
    ("30 lines/s of 80 bytes", "producer.py"),
]


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        stat = f.read()
    fields = stat[stat.rindex(")") + 2 :].split()
    # fields[0] is field 3 (state); utime and stime are fields 14 and 15.
    return int(fields[11]) + int(fields[12])


def context_switches(pid):
    total = 0
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith(("voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:")):
                total += int(line.split()[1])
    return total


class Outer:
    def __init__(self, argv, env, cwd):
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
        self.bytes = 0
        self.tail = b""

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

    def wait_for(self, needle, seconds=10):
        end = time.monotonic() + seconds
        while needle not in self.tail:
            if time.monotonic() > end:
                raise RuntimeError(f"timed out waiting for {needle!r}")
            self.pump(0.05)

    def send(self, data):
        os.write(self.fd, data)

    def close(self):
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


class Kiwa:
    name = "kiwa"

    def __init__(self, binary, work):
        self.binary = binary
        self.env = base_env(work)
        self.env["KIWA_SOCKET"] = os.path.join(work, "kiwa.sock")
        self.env["KIWA_STATE_DIR"] = os.path.join(work, "state")
        self.work = work
        self.outer = Outer([binary], self.env, work)
        self.outer.wait_for(b"$")
        self.server = self.find_server()

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

    def pids(self):
        return [self.server, self.outer.pid]

    def stop(self):
        subprocess.run([self.binary, "kill-server"], env=self.env, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.outer.close()
        for _ in range(100):
            if not os.path.exists(f"/proc/{self.server}"):
                return
            time.sleep(0.05)
        os.kill(self.server, signal.SIGKILL)


class Tmux:
    name = "tmux"
    count = 0

    def __init__(self, binary, work):
        Tmux.count += 1
        self.binary = binary
        self.socket = f"kiwa-bench-{os.getpid()}-{Tmux.count}"
        self.env = base_env(work)
        self.base = [binary, "-L", self.socket, "-f", "/dev/null"]
        # The status line is off so both multiplexers show a 100x40 pane.
        subprocess.run(self.base + ["new-session", "-d", "-x", str(COLS), "-y", str(ROWS),
                                    "-c", work, "/bin/sh", ";", "set", "-g", "status", "off"],
                       env=self.env, check=True, timeout=10)
        pid, self.socket_path = subprocess.run(
            self.base + ["display-message", "-p", "#{pid} #{socket_path}"],
            env=self.env, check=True, timeout=10, capture_output=True, text=True).stdout.split()
        self.server = int(pid)
        self.outer = Outer(self.base + ["attach-session"], self.env, work)
        self.outer.wait_for(b"$")

    def pids(self):
        return [self.server, self.outer.pid]

    def stop(self):
        subprocess.run(self.base + ["kill-server"], env=self.env, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.outer.close()
        # tmux leaves its socket file behind after kill-server.
        if os.path.basename(self.socket_path) == self.socket:
            try:
                os.unlink(self.socket_path)
            except FileNotFoundError:
                pass


def measure(variant_cls, binary, scenario, scripts, warmup, sample):
    work = tempfile.mkdtemp(prefix=f"kiwa-bench-{variant_cls.name}-")
    v = None
    try:
        v = variant_cls(binary, work)
        v.outer.pump(0.5)
        if scenario[1]:
            v.outer.send(f"python3 {os.path.join(scripts, scenario[1])}\r".encode())
        v.outer.pump(warmup)
        pids = v.pids()
        before = sum(cpu_ticks(p) for p in pids)
        switches_before = sum(context_switches(p) for p in pids)
        v.outer.bytes = 0
        start = time.monotonic()
        v.outer.pump(sample)
        elapsed = time.monotonic() - start
        ticks = sum(cpu_ticks(p) for p in pids) - before
        switches = sum(context_switches(p) for p in pids) - switches_before
        return {
            "switches": switches,
            "cpu": 100.0 * ticks / CLK_TCK / elapsed,
            "ticks": ticks,
            "bytes": v.outer.bytes,
            "tail": v.outer.tail,
        }
    finally:
        if v is not None:
            v.stop()
        shutil.rmtree(work, ignore_errors=True)


def check_work(scenario, result):
    """Fails a run whose producer never reached the outer terminal."""
    name, script = scenario
    if script == "spinner.py" and result["bytes"] == 0:
        raise RuntimeError(f"{name}: the spinner produced no outer bytes")
    if script == "producer.py" and b"lorem" not in result["tail"]:
        raise RuntimeError(f"{name}: producer lines never reached the outer terminal")


def summarize(values, fmt):
    med = statistics.median(values)
    return f"{fmt(med)} ({fmt(min(values))} to {fmt(max(values))})"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("kiwa")
    ap.add_argument("--build", default="unknown", help="Kiwa's optimize mode, for the report")
    ap.add_argument("--tmux", default=shutil.which("tmux") or "tmux")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--warmup", type=float, default=6.0)
    ap.add_argument("--sample", type=float, default=12.0)
    args = ap.parse_args()
    kiwa = os.path.abspath(args.kiwa)

    scripts = tempfile.mkdtemp(prefix="kiwa-bench-scripts-")
    for name, text in (("spinner.py", SPINNER), ("producer.py", PRODUCER)):
        with open(os.path.join(scripts, name), "w") as f:
            f.write(text)

    tmux_version = subprocess.run([args.tmux, "-V"], capture_output=True, text=True).stdout.strip()
    kiwa_version = subprocess.run([kiwa, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"{kiwa_version}, build {args.build}; {tmux_version}", flush=True)
    print(f"{COLS}x{ROWS}, warmup {args.warmup:g} s, sample {args.sample:g} s, {args.runs} runs, "
          f"load {os.getloadavg()[0]:.2f}, {os.cpu_count()} CPUs", flush=True)
    tick_pct = 100.0 / CLK_TCK / args.sample
    print(f"tick resolution: 1 tick = {1000 / CLK_TCK:g} ms = {tick_pct:.3f}% of one core over the sample",
          flush=True)

    variants = {"kiwa": (Kiwa, kiwa), "tmux": (Tmux, args.tmux)}
    results = {}
    try:
        for scenario in SCENARIOS:
            for run in range(args.runs):
                # Alternating keeps drift and warm caches from favoring one side.
                order = ["kiwa", "tmux"] if run % 2 == 0 else ["tmux", "kiwa"]
                for name in order:
                    cls, binary = variants[name]
                    r = measure(cls, binary, scenario, scripts, args.warmup, args.sample)
                    check_work(scenario, r)
                    results.setdefault((scenario[0], name), []).append(r)
                    print(f"  {scenario[0]} run {run + 1} {name}: {r['ticks']} ticks, "
                          f"{r['cpu']:.3f}% CPU, {r['bytes']} bytes, "
                          f"{r['switches']} context switches", flush=True)
    finally:
        shutil.rmtree(scripts, ignore_errors=True)

    print()
    print(f"| Scenario | Variant | CPU % of one core, median (range) | Outer bytes in {args.sample:g} s, median (range) | Ticks per run | Context switches, median |")
    print("|---|---|---|---|---|---|")
    for scenario in SCENARIOS:
        for name in ("kiwa", "tmux"):
            rs = results[(scenario[0], name)]
            cpu = summarize([r["cpu"] for r in rs], lambda v: f"{v:.2f}")
            out = summarize([r["bytes"] for r in rs], lambda v: f"{v:,.0f}")
            ticks = ", ".join(str(r["ticks"]) for r in rs)
            switches = statistics.median(r["switches"] for r in rs)
            label = f"Kiwa ({args.build})" if name == "kiwa" else tmux_version
            print(f"| {scenario[0]} | {label} | {cpu} | {out} | {ticks} | {switches:,.0f} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
