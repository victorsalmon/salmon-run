#!/usr/bin/env python3
"""Local test fixture: a fake gallery site hosting synthetic non-explicit images.

Serves:
  /comics/demo/page?page=N   -> HTML page with one full-size image + lazy attrs
  /comics/demo/1..5.png      -> synthetic PNG files

Run:  python fixture_server.py
Then: python scraper.py http://127.0.0.1:8765/comics/demo/page --end 3
"""

import http.server
import io
import socketserver
import struct
import zlib

HOST, PORT = "127.0.0.1", 8765

PAGES = 5
IMG_W, IMG_H = 640, 480


def make_png(page: int) -> bytes:
    """Generate a tiny solid-color PNG using zlib (no external deps)."""
    channels = 3
    row = bytes([0]) + bytes([page * 40 % 255, 120, 255 - page * 40 % 255]) * IMG_W
    raw = row * IMG_H

    def chunk(kind: bytes, data: bytes) -> bytes:
        c = struct.pack(">I", len(data)) + kind + data
        c += struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        return c

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", IMG_W, IMG_H, 8, 2, 0, 0, 0)
    idat = zlib.compress(raw)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/comics/demo/"):
            name = self.path.rsplit("/", 1)[-1]
            if name.startswith("page"):
                self.serve_page()
            elif name.endswith(".png"):
                page = int(name[0])
                body = make_png(page)
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_error(404)
        else:
            self.send_error(404)

    def serve_page(self):
        from urllib.parse import parse_qs, urlparse, urlunparse

        qs = parse_qs(urlparse(self.path).query)
        page = int(qs.get("page", ["1"])[0])
        num = max(1, min(page, PAGES))

        raw = io.BytesIO()

        write_attrs = {
            1: 'src="/comics/demo/1.png" class="lazy" data-full-src="/comics/demo/1.png"',
            2: 'data-src="/comics/demo/2.png"',
            3: 'srcset="/comics/demo/3-small.png 300w, /comics/demo/3.png 1280w"',
            4: 'src="/page/thumb/4.jpg" data-original="/comics/demo/4.png"',
            5: 'src="/comics/demo/5.png"',
        }[num]

        body = b""
        body += f"""<!DOCTYPE html><html><head>
<title>Demo Gallery - Page {num} of {PAGES} - FixtureSite</title>
</head><body>
<h1>Demo Gallery</h1>
<img id="main" {write_attrs} />
""".encode()
        if num < PAGES:
            body += (
                f'<a rel="next" href="/comics/demo/page?page={num + 1}">Next</a>'
            ).encode()
        body += b"</body></html>"

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    with socketserver.ThreadingTCPServer((HOST, PORT), Handler) as httpd:
        print(f"Fixture server on http://{HOST}:{PORT}")
        httpd.serve_forever()