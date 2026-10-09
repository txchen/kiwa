#!/usr/bin/env python3
"""TCP proxy :2223 -> :2222 that adds one-way delay (and optional bandwidth cap).

Delay is read from /tmp/rproto/delay_ms ("<one_way_ms> [kbytes_per_s]") on every
chunk, so long-lived connections (ssh ControlPersist masters) follow changes. Byte counters for down (server->client) and up are written to
/tmp/rproto/bytes as "<up> <down>".
"""
import asyncio, time, os

R = "/tmp/rproto"
counts = {"up": 0, "down": 0}


def write_counts():
    with open(R + "/bytes.tmp", "w") as f:
        f.write(f"{counts['up']} {counts['down']}\n")
    os.replace(R + "/bytes.tmp", R + "/bytes")


_cfg = {"mtime": None, "val": (0.0, 0.0)}


def read_cfg():
    try:
        m = os.stat(R + "/delay_ms").st_mtime_ns
    except FileNotFoundError:
        return 0.0, 0.0
    if m != _cfg["mtime"]:
        _cfg["mtime"], _cfg["val"] = m, _read_cfg()
    return _cfg["val"]


def _read_cfg():
    try:
        parts = open(R + "/delay_ms").read().split()
    except FileNotFoundError:
        return 0.0, 0.0
    d = float(parts[0]) / 1000
    rate = float(parts[1]) * 1024 if len(parts) > 1 else 0.0
    return d, rate


async def pump(reader, writer, key):
    q = asyncio.Queue()
    last_tx = [0.0]

    async def sender():
        while True:
            due, data = await q.get()
            if data is None:
                writer.close()
                return
            now = time.monotonic()
            if due > now:
                await asyncio.sleep(due - now)
            writer.write(data)
            await writer.drain()

    task = asyncio.create_task(sender())
    while True:
        data = await reader.read(65536)
        now = time.monotonic()
        delay, rate = read_cfg()
        if not data:
            await q.put((now + delay, None))
            break
        counts[key] += len(data)
        write_counts()
        if rate:
            start = max(now, last_tx[0])
            last_tx[0] = start + len(data) / rate
            due = last_tx[0] + delay
        else:
            due = now + delay
        await q.put((due, data))
    await task


async def handle(cr, cw):
    sr, sw = await asyncio.open_connection("127.0.0.1", 2222)
    for s in (cw, sw):
        s.transport.get_extra_info("socket").setsockopt(6, 1, 1)  # TCP_NODELAY
    await asyncio.gather(
        pump(cr, sw, "up"), pump(sr, cw, "down"),
        return_exceptions=True)


async def main():
    write_counts()
    srv = await asyncio.start_server(handle, "127.0.0.1", 2223)
    async with srv:
        await srv.serve_forever()


asyncio.run(main())
