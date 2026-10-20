import socket, sys, threading, time, struct
mode, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(64)
t0 = time.monotonic(); keep = []
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
    else:
        keep.append(c)
