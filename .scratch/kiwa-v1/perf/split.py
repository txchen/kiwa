import subprocess, sys, time, os
kiwa, scenario = sys.argv[1], sys.argv[2]
if os.path.exists("/tmp/kiwa-prof/current"): os.remove("/tmp/kiwa-prof/current")
drv = subprocess.Popen(["python3", "" + os.path.join(os.path.dirname(os.path.abspath(__file__)), "drive.py") + "", kiwa, scenario, "18"], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
while not os.path.exists("/tmp/kiwa-prof/current"): time.sleep(0.1)
d = open("/tmp/kiwa-prof/current").read()
while not os.path.exists(d + "/pids"): time.sleep(0.1)
srv, cli = open(d + "/pids").read().split()
time.sleep(3)
def st(p):
    f = open(f"/proc/{p}/stat").read().rsplit(")",1)[1].split()
    return int(f[11]), int(f[12])
a = st(srv); time.sleep(12); b = st(srv)
print(scenario, "server utime", b[0]-a[0], "stime", b[1]-a[1], "ticks in 12 s")
drv.wait()
