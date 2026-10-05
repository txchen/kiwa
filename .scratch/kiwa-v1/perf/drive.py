import os, pty, sys, time, fcntl, termios, struct, select, subprocess, tempfile, signal
kiwa, scenario, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
os.makedirs("/tmp/kiwa-prof", exist_ok=True)
d = tempfile.mkdtemp(prefix="kiwa-prof-")
env = {"PATH": "/usr/bin:/bin", "HOME": d, "SHELL": "/bin/sh", "PS1": "$ ", "TERM": "xterm-256color",
       "KIWA_SOCKET": d + "/s.sock", "KIWA_STATE_DIR": d + "/state"}
spinner = d + "/spin.py"
open(spinner, "w").write("import sys,time\nc='|/-\\\\'\ni=0\nwhile True:\n sys.stdout.write('\\r'+c[i%4]); sys.stdout.flush(); i+=1; time.sleep(1/60)\n")
lines = d + "/lines.py"
open(lines, "w").write("import sys,time\nw='alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma '\ni=0\nwhile True:\n k=i%len(w); sys.stdout.write('%08d '%i+(w[k:]+w)[:70]+'\\n'); sys.stdout.flush(); i+=1; time.sleep(1/30)\n")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(d); os.execve(kiwa, [kiwa], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
def pump(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: os.read(fd, 65536)
            except OSError: return
pump(1.5)
os.write(fd, ("python3 %s\r" % (spinner if scenario == "spinner" else lines)).encode())
pump(2)
srv = subprocess.run(["pgrep", "-f", "__server"], capture_output=True, text=True).stdout.split()
srv = [p for p in srv if d.encode() in open(f"/proc/{p}/environ", "rb").read()]
print("server", srv[0], "client", pid, "dir", d, flush=True)
open(d + "/pids", "w").write(f"{srv[0]} {pid}\n")
open("/tmp/kiwa-prof/current", "w").write(d)
pump(secs)
os.write(fd, b"\x03"); pump(0.5)
subprocess.run([kiwa, "kill-server"], env=env)
pump(1)
