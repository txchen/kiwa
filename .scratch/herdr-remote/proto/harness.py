#!/usr/bin/env python3
"""Drive a multiplexer client in a PTY as a fake outer terminal and time interactions.

usage: harness.py <variant> <scenario> [--trials N] [--out file.jsonl]
"""
import argparse, json, os, pty, re, select, signal, statistics, struct, fcntl, termios
import threading, time, random, subprocess, sys
import pyte

R = "/tmp/rproto"
P = os.path.dirname(os.path.abspath(__file__))
SSH = ["ssh", "-F", f"{R}/local/.ssh/config"] + os.environ.get("SSHOPTS", "").split()
COLS, ROWS = 160, 45

VARIANTS = {
    "kiwa-local": ["bash", "-c", f". {R}/remote/env.sh; cd; exec kiwa"],
    "herdr-local": ["bash", "-c", f". {R}/remote/env.sh; cd; exec herdr"],
    "kiwa-ssh": SSH + ["-t", "lagbox", "kiwa"],
    "herdr-ssh": SSH + ["-t", "lagbox", "herdr"],
    "kiwa-ssh-noobscure": SSH + ["-o", "ObscureKeystrokeTiming=no", "-t", "lagbox", "kiwa"],
    "kiwa-ssh-tuned": SSH + ["-C", "-o", "ObscureKeystrokeTiming=no", "-t", "lagbox", "kiwa"],
    "herdr-ssh-noobscure": SSH + ["-o", "ObscureKeystrokeTiming=no", "-t", "lagbox", "herdr"],
    "herdr-remote": ["herdr", "--remote", "lagbox"],
    "shell-ssh": SSH + ["-t", "lagbox"],
    "shell-local": ["bash", "-c", f". {R}/remote/env.sh; cd; exec bash -i"],
}


def local_env():
    env = {"TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "C.UTF-8"}
    for line in open(f"{R}/local/env.sh"):
        for kv in line.replace("export ", "").split():
            k, v = kv.split("=", 1)
            env[k] = v
    return env


class Screen(pyte.Screen):
    def report_device_status(self, *a, **k):
        pass

    def select_graphic_rendition(self, *a, **k):
        k.pop("private", None)
        super().select_graphic_rendition(*a)

    def set_mode(self, *a, **k):
        try:
            super().set_mode(*a, **k)
        except Exception:
            pass


class Term:
    def __init__(self, argv):
        self.screen = Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.lock = threading.Condition()
        self.rx = 0
        self.last_rx = time.monotonic()
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(argv[0], argv, local_env())
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, COLS * 9, ROWS * 18))
        self.alive = True
        self.parse = True
        self.token = None
        self.token_at = None
        self.tail = b""
        self.capture = None
        threading.Thread(target=self._reader, daemon=True).start()

    def _answer(self, data):
        # Minimal terminal replies so clients do not wait on query timeouts.
        if b"\x1b[c" in data or b"\x1b[0c" in data:
            self.send(b"\x1b[?62;22c")
        if b"\x1b[6n" in data:
            y, x = self.screen.cursor.y + 1, self.screen.cursor.x + 1
            self.send(f"\x1b[{y};{x}R".encode())
        if b"\x1b[?u" in data:
            pass  # claim no kitty keyboard support
        if b"\x1b]10;?" in data:
            self.send(b"\x1b]10;rgb:cccc/cccc/cccc\x1b\\")
        if b"\x1b]11;?" in data:
            self.send(b"\x1b]11;rgb:1111/1111/1111\x1b\\")
        for m in re.finditer(rb"\x1b\[\?(\d+)\$p", data):
            self.send(b"\x1b[?" + m.group(1) + b";2$y")
        if b"\x1b[14t" in data:
            self.send(f"\x1b[4;{ROWS*18};{COLS*9}t".encode())
        if b"\x1b[16t" in data:
            self.send(b"\x1b[6;18;9t")
        if b"\x1b[18t" in data:
            self.send(f"\x1b[8;{ROWS};{COLS}t".encode())

    def _reader(self):
        while True:
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                data = b""
            if not data:
                with self.lock:
                    self.alive = False
                    self.lock.notify_all()
                return
            now = time.monotonic()
            self._answer(data)
            with self.lock:
                self.rx += len(data)
                self.last_rx = now
                if self.token and self.token_at is None and self.token in self.tail + data:
                    self.token_at = now
                self.tail = data[-8:]
                if self.capture is not None:
                    self.capture += data
                if self.parse:
                    try:
                        self.stream.feed(data)
                    except Exception as e:
                        print("pyte:", repr(e), file=sys.stderr)
                self.lock.notify_all()

    def send(self, b):
        os.write(self.fd, b)

    def text(self):
        return "\n".join(self.screen.display)

    def wait(self, pred, timeout=10.0):
        """Return the monotonic time at which pred(screen text) first held."""
        end = time.monotonic() + timeout
        with self.lock:
            while True:
                if pred(self.text()):
                    # Arrival time of the bytes that made pred true, not check time.
                    return self.last_rx
                left = end - time.monotonic()
                if left <= 0 or not self.alive:
                    raise TimeoutError(self.text())
                self.lock.wait(left)

    def settle(self, quiet=0.3, timeout=10):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            with self.lock:
                idle = time.monotonic() - self.last_rx
            if idle >= quiet:
                return
            time.sleep(0.02)

    def close(self):
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass


def proxy_bytes():
    try:
        up, down = open(f"{R}/bytes").read().split()
        return int(up), int(down)
    except Exception:
        return 0, 0


PREFIX = b"\x02"


def run_cmd(t, cmd, marker, timeout=15):
    t.send(cmd.encode() + b"\r")
    t.wait(lambda s: marker in s, timeout)


ONE, TWO = "Л", "Д"


def setup_tabs(t):
    """Tab 1 shows ЛЛЛЛ, tab 2 shows ДДДД; ends on tab 1."""
    run_cmd(t, "clear; printf '\\u041b%.0s' 1 2 3 4; echo", ONE * 4)
    t.send(PREFIX + b"c")
    time.sleep(1.0)
    if "new tab" in t.text():  # Herdr asks for confirmation
        t.send(b"\r")
    t.wait(lambda s: ONE not in s, 10)
    t.settle(0.5)
    run_cmd(t, "clear; printf '\\u0414%.0s' 1 2 3 4; echo", TWO * 4)
    t.send(PREFIX + b"p")
    t.wait(lambda s: ONE in s and TWO not in s)
    t.settle(0.5)


def wait_token(t, token, keys, timeout=15):
    with t.lock:
        t.token, t.token_at, t.tail = token.encode(), None, b""
    t0 = time.monotonic()
    t.send(keys)
    end = t0 + timeout
    with t.lock:
        while t.token_at is None:
            if time.monotonic() > end:
                raise TimeoutError(f"token {token} never arrived")
            t.lock.wait(0.5)
        t.token = None
        return t.token_at - t0


def trial_tabswitch(t, i):
    token, key = (TWO, b"n") if i % 2 == 0 else (ONE, b"p")
    dt = wait_token(t, token, PREFIX + key)
    time.sleep(0.3)
    return dt


def trial_echo(t, i):
    """Type one character whose UTF-8 bytes never occur in escapes or the flood."""
    with t.lock:
        t.token, t.token_at, t.tail = "Ж".encode(), None, b""
    t0 = time.monotonic()
    t.send("Ж".encode())
    end = t0 + 15
    with t.lock:
        while t.token_at is None:
            if time.monotonic() > end:
                raise TimeoutError("echo token never arrived")
            t.lock.wait(0.5)
        t1 = t.token_at
        t.token = None
    t.send(b"\x15")  # ctrl+u
    time.sleep(0.3)
    return t1 - t0


def trial_echo_screen(t, i):
    ch = random.choice("abcdefghijkmnopqrstuvwxyz")
    mark = f"Q{i:03d}{ch}"
    t.send(mark[:-1].encode())
    t.wait(lambda s: mark[:-1] in s)
    t.settle(0.15)
    t0 = time.monotonic()
    t.send(ch.encode())
    t1 = t.wait(lambda s: mark in s)
    t.send(b"\x15")  # ctrl+u
    t.wait(lambda s: mark not in s)
    return t1 - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("variant")
    ap.add_argument("scenario", choices=["tabswitch", "echo", "echo-flood", "flood-bytes", "capture", "screen"])
    ap.add_argument("--trials", type=int, default=10)
    ap.add_argument("--delay", default="0", help="one-way ms [KB/s] written to delay_ms")
    ap.add_argument("--out")
    a = ap.parse_args()
    open(f"{R}/delay_ms", "w").write(a.delay.replace(",", " ") + "\n")

    name, _, build = a.variant.partition("@")
    argv = list(VARIANTS[name])
    if build:  # kiwa-ssh-tuned@16 runs /tmp/rproto/kiwa-16/bin/kiwa
        kb = f"{P}/kiwa-{build}/bin/kiwa"
        argv = [kb if x == "kiwa" else x.replace("exec kiwa", f"exec {kb}") for x in argv]
    t = Term(argv)
    res = {"variant": a.variant, "scenario": a.scenario, "delay": a.delay}
    try:
        t.wait(lambda s: "$ " in s, 30)
        t.settle(1.0)
        if a.scenario == "screen":
            print(t.text())
            return
        if a.scenario == "tabswitch":
            setup_tabs(t)
            fn = trial_tabswitch
            t.parse = False
        elif a.scenario in ("echo", "echo-flood", "flood-bytes", "capture"):
            if a.scenario != "echo":
                # Left pane floods output; focus returns to the right pane.
                t.send(PREFIX + b"v")
                t.settle(0.5)
                t.send(PREFIX + b"h")
                t.settle(0.3)
                t.send(b"while :; do printf '%s %s %s\\n' $RANDOM $RANDOM $RANDOM; done\r")
                time.sleep(1.0)
                t.send(PREFIX + b"l")
                t.settle(0.05, 2)
                time.sleep(1.0)
            if a.scenario == "capture":
                t.parse = False
                with t.lock:
                    t.capture = bytearray()
                time.sleep(5)
                with t.lock:
                    buf, t.capture = bytes(t.capture), None
                open(a.out or "capture.bin", "wb").write(buf)
                frames = buf.count(b"\x1b[?2026h")
                res.update(bytes_per_s=len(buf) / 5, frames_per_s=frames / 5,
                           bytes_per_frame=len(buf) / max(frames, 1))
                print(json.dumps(res))
                return
            if a.scenario == "flood-bytes":
                u0, d0 = proxy_bytes()
                rx0 = t.rx
                time.sleep(5)
                u1, d1 = proxy_bytes()
                res.update(wire_down_Bps=(d1 - d0) / 5, wire_up_Bps=(u1 - u0) / 5,
                           pty_Bps=(t.rx - rx0) / 5)
                print(json.dumps(res))
                return
            fn = trial_echo
            t.parse = False
        u0, d0 = proxy_bytes()
        rx0 = t.rx
        samples = []
        tstart = time.monotonic()
        for i in range(a.trials):
            samples.append(round(fn(t, i) * 1000, 1))
            if fn in (trial_echo, trial_tabswitch):
                time.sleep(0.2)
            else:
                t.settle(0.2, 3)
        u1, d1 = proxy_bytes()
        dur = time.monotonic() - tstart
        res.update(dur_s=round(dur, 2), pty_Bps=round((t.rx - rx0) / dur), ms=samples, median_ms=statistics.median(samples),
                   min_ms=min(samples), max_ms=max(samples),
                   wire_down=d1 - d0, wire_up=u1 - u0, pty_rx=t.rx - rx0)
        print(json.dumps(res))
        if a.out:
            open(a.out, "a").write(json.dumps(res) + "\n")
    except TimeoutError as e:
        res["error"] = "timeout"
        print(json.dumps(res))
        print(str(e)[-3000:], file=sys.stderr)
        sys.exit(1)
    finally:
        t.close()


if __name__ == "__main__":
    main()
