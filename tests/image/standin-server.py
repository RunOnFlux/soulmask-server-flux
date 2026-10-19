#!/usr/bin/env python3
"""A stand-in for WSServer-Linux-Shipping in the image test: the parts of Soulmask the supervisor
relies on, with the answers the real server gives (build 25955350)."""
import json, os, signal, socket, sys, threading, time

if os.getuid() == 0:
    sys.exit("refusing to run as root")
here = os.path.dirname(os.path.abspath(__file__))
ws = os.path.abspath(os.path.join(here, "..", ".."))
saved = os.path.join(ws, "Saved")
the_map = sys.argv[2] if len(sys.argv) > 2 else "Level01_Main"
log = open(os.path.join(saved, "Logs", "WS.log"), "a", buffering=1)
log.write("LogInit: Command Line: " + " ".join(sys.argv[2:]) + "\n")
world_dir = os.path.join(saved, "Worlds", "Dedicated", the_map)
os.makedirs(world_dir, exist_ok=True)
xishu = os.path.join(saved, "GameplaySettings", "GameXishu.json")
bans = os.path.join(saved, "BlackAccountList.txt")
exiting = []


def save():
    import sqlite3
    c = sqlite3.connect(os.path.join(world_dir, "world.db"))
    c.execute("create table if not exists t(v)")
    c.execute("insert into t values (?)", (time.time(),))
    c.commit()
    c.close()
    return "[WORLD IS SAVED TO:] ../../../WS/Saved/Worlds/Dedicated/%s/world.db succeed\n" % the_map


def answer(cmd):
    words = cmd.split()
    if not words:
        return ""
    w = words[0].lower()
    if w == "sav" and words[1:] == ["1"]:
        return save()
    if w == "qi":
        return "STANDINCODE1234567890\n"
    if w == "lp":
        return ("|              Account |                       PlayerName |                    PawnID |                       Position |\n"
                "|    76561198000000001 |                        Chief Ana |                     12345 |  X=1.0 Y=2.0 Z=3.0 |\n")
    if w == "say":
        return "send to all online players. Done.\n"
    if w == "sc" and len(words) == 3:
        d = json.load(open(xishu)) if os.path.exists(xishu) else {"0": {}, "1": {}, "2": {}}
        d["1"][words[1]] = float(words[2]) if "." in words[2] else int(words[2])
        os.makedirs(os.path.dirname(xishu), exist_ok=True)
        json.dump(d, open(xishu, "w"))
        return "%s: %.3f (updated)\n" % (words[1], float(words[2]))
    if w == "usp" and len(words) == 4:
        ids = [l.strip() for l in open(bans)] if os.path.exists(bans) else []
        ids = [i for i in ids if i and i != words[3]] + ([words[3]] if words[2] == "1" else [])
        open(bans, "w").write("".join(i + "\n" for i in ids))
        return "done.\n"
    if w == "lsp":
        ids = [l.strip() for l in open(bans)] if os.path.exists(bans) else []
        return ("==== SERVER PERMISSION DETAILS ====\n1. BlackAccountList\n    status: Yes\n    values:\n"
                + "".join("    |   %s\n" % i for i in ids))
    if w == "close" and len(words) == 2:
        exiting.append(time.time() + int(words[1]))
        return "server will close in %s seconds\n" % words[1]
    return "%s Not Found!\n" % words[0]


def serve():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 18888))
    srv.listen(5)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=client, args=(conn,), daemon=True).start()


def client(conn):
    buf = b""
    with conn:
        while True:
            data = conn.recv(4096)
            if not data:
                return
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                conn.sendall(answer(line.decode().strip()).encode())


def stop(*_):
    log.write("LogExit: Exiting.\n")
    sys.exit(0)


signal.signal(signal.SIGTERM, stop)
threading.Thread(target=serve, daemon=True).start()
time.sleep(1)
log.write("logStoreGamemode: Display: [ GAME STARTED. ]\n")
while True:
    time.sleep(0.2)
    if exiting and time.time() >= exiting[0]:
        save()
        stop()
