# listener.py MODE PORT [UPSTREAM_PORT BOOT_S]: a stand-in gate for the ssh-ng client.
# hold keeps every connection open and silent; rst resets; fin half-closes; close closes.
# boot holds connections until BOOT_S after start, then splices them to UPSTREAM_PORT,
# which is what nbh-gate's hold mode does while a builder boots.
import socket, sys, threading, time, struct
mode, port = sys.argv[1], int(sys.argv[2])
up = int(sys.argv[3]) if len(sys.argv) > 3 else 0
boot = float(sys.argv[4]) if len(sys.argv) > 4 else 0
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(64)
t0 = time.monotonic(); keep = []
def pipe(a, b):
    try:
        while (d := a.recv(65536)):
            b.sendall(d)
    except OSError:
        pass
    try: b.shutdown(socket.SHUT_WR)
    except OSError: pass
def splice(c):
    time.sleep(max(0, boot - (time.monotonic() - t0)))
    u = socket.create_connection(("127.0.0.1", up))
    print(f"{time.monotonic()-t0:6.2f} splice", flush=True)
    threading.Thread(target=pipe, args=(c, u), daemon=True).start()
    pipe(u, c)
while True:
    c, _ = s.accept()
    print(f"{time.monotonic()-t0:6.2f} accept", flush=True)
    if mode == "rst":
        c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); c.close()
    elif mode == "fin":
        c.shutdown(socket.SHUT_WR); c.settimeout(2)
        try:
            while c.recv(65536): pass
        except Exception: pass
        c.close()
    elif mode == "close":
        c.close()
    elif mode == "boot":
        threading.Thread(target=splice, args=(c,), daemon=True).start()
    else:
        keep.append(c)
