import subprocess, sys, time, os
kiwa, scenario, out, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
if os.path.exists("/tmp/kiwa-prof/current"): os.remove("/tmp/kiwa-prof/current")
drv = subprocess.Popen(["python3", "" + os.path.join(os.path.dirname(os.path.abspath(__file__)), "drive.py") + "", kiwa, scenario, "14"], stdout=open("/tmp/kiwa-prof/drive.log","w"), stderr=subprocess.STDOUT)
while not os.path.exists("/tmp/kiwa-prof/current"): time.sleep(0.1)
d = open("/tmp/kiwa-prof/current").read()
while not os.path.exists(d + "/pids"): time.sleep(0.1)
srv, cli = open(d + "/pids").read().split()
time.sleep(2)
def ticks(p):
    f = open(f"/proc/{p}/stat").read().rsplit(")",1)[1].split()
    return int(f[11]) + int(f[12])
t0 = (ticks(srv), ticks(cli))
args = ["perf", "record", "-q", "-F", "2000", "--call-graph", "dwarf,16384", "-o", out, "-p", srv] + extra + ["--", "sleep", "8"]
subprocess.run(args)
t1 = (ticks(srv), ticks(cli))
print("server ticks", t1[0]-t0[0], "client ticks", t1[1]-t0[1], "over ~8 s (perf overhead included)")
drv.wait()
