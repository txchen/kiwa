"""Server CPU in schedstat nanoseconds for one or more kiwa binaries.

    sched.py <spinner|lines> <rounds> <kiwa>...

Runs each binary through drive.py in turn, `rounds` times, alternating
binaries so that drift hits them alike, and prints the server's and
client's CPU time in ms over a 12 s sample from /proc/<pid>/schedstat.
"""
import os, subprocess, sys, time

scenario, rounds, kiwas = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
drive = os.path.join(os.path.dirname(os.path.abspath(__file__)), "drive.py")


def ns(pid):
    return int(open(f"/proc/{pid}/schedstat").read().split()[0])


def sample(kiwa):
    if os.path.exists("/tmp/kiwa-prof/current"):
        os.remove("/tmp/kiwa-prof/current")
    drv = subprocess.Popen(["python3", drive, kiwa, scenario, "18"], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    while not os.path.exists("/tmp/kiwa-prof/current"):
        time.sleep(0.1)
    d = open("/tmp/kiwa-prof/current").read()
    while not os.path.exists(d + "/pids"):
        time.sleep(0.1)
    srv, cli = open(d + "/pids").read().split()
    time.sleep(3)
    a = (ns(srv), ns(cli))
    time.sleep(12)
    b = (ns(srv), ns(cli))
    drv.wait()
    return (b[0] - a[0]) / 1e6, (b[1] - a[1]) / 1e6


results = {k: [] for k in kiwas}
for _ in range(rounds):
    for k in kiwas:
        results[k].append(sample(k))
for k in kiwas:
    srv = sorted(r[0] for r in results[k])
    cli = sorted(r[1] for r in results[k])
    print(f"{scenario} {k}: server ms {' '.join(f'{v:.1f}' for v in srv)} | client ms {' '.join(f'{v:.1f}' for v in cli)}")
