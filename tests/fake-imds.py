"""IMDSv2 stand-in: PUT /latest/api/token, then GET /latest/user-data with the token."""
import http.server
import secrets
import sys

USER_DATA, PORT = sys.argv[1], int(sys.argv[2])
tokens = set()


class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        if self.path != "/latest/api/token":
            return self.send_error(404)
        t = secrets.token_hex(16)
        tokens.add(t)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(t.encode())

    def do_GET(self):
        if self.headers.get("X-aws-ec2-metadata-token") not in tokens:
            return self.send_error(401)
        if self.path != "/latest/user-data":
            return self.send_error(404)
        try:
            body = open(USER_DATA, "rb").read()
        except FileNotFoundError:
            return self.send_error(404)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
