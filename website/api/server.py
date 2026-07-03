#!/usr/bin/env python3
"""
Fotobox Settings API
- Läuft auf 127.0.0.1:3000
- nginx proxied /api/ → hier
- Endpunkte: GET/POST /api/settings | GET/POST /api/status | GET /api/info
"""
import json
import os
import re
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler

SETTINGS_FILE = '/var/www/fotobox/settings.json'
STATUS_FILE   = '/tmp/fotobox_status.json'
PORT          = 3000

DEFAULT_SETTINGS = {
    'video_duration':   45,
    'gallery_duration': 45,
    'gallery_url':      'https://fotoshare.co/e/MT9Ze_2AcJL-7hC1H4kJL'
}

# ── Hilfsfunktionen ──────────────────────────────────────────────────────────

def read_json(path, default):
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except Exception:
        return dict(default)

def write_json(path, data):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)   # atomares Schreiben

def get_local_ip():
    """Lokale IP-Adresse im LAN ermitteln."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return '127.0.0.1'

# ── HTTP Handler ─────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass  # Zugriffe nicht in stdout fluten

    def send_json(self, code, data):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type',  'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        try:
            length = int(self.headers.get('Content-Length', 0))
            if length <= 0 or length > 65536:
                return {}
            raw = self.rfile.read(length)
            return json.loads(raw.decode())
        except Exception:
            return {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Allow', 'GET, POST, OPTIONS')
        self.end_headers()

    # ── GET ──────────────────────────────────────────────────

    def do_GET(self):
        path = self.path.split('?')[0]   # Query-String ignorieren

        if path == '/api/settings':
            self.send_json(200, read_json(SETTINGS_FILE, DEFAULT_SETTINGS))

        elif path == '/api/status':
            default = {'mode': 'unknown', 'next_switch_in': 0}
            self.send_json(200, read_json(STATUS_FILE, default))

        elif path == '/api/info':
            self.send_json(200, {'ip': get_local_ip()})

        else:
            self.send_json(404, {'error': 'Not found'})

    # ── POST ─────────────────────────────────────────────────

    def do_POST(self):
        path = self.path.split('?')[0]

        if path == '/api/settings':
            data    = self.read_body()
            current = read_json(SETTINGS_FILE, DEFAULT_SETTINGS)

            # video_duration: 1–3600 Sek.
            if 'video_duration' in data:
                try:
                    val = int(data['video_duration'])
                    if 1 <= val <= 3600:
                        current['video_duration'] = val
                except (ValueError, TypeError):
                    pass

            # gallery_duration: 1–3600 Sek.
            if 'gallery_duration' in data:
                try:
                    val = int(data['gallery_duration'])
                    if 1 <= val <= 3600:
                        current['gallery_duration'] = val
                except (ValueError, TypeError):
                    pass

            # gallery_url: nur http/https erlaubt
            if 'gallery_url' in data:
                url = str(data['gallery_url']).strip()
                if re.match(r'^https?://[^\s]{4,}', url):
                    current['gallery_url'] = url

            write_json(SETTINGS_FILE, current)
            self.send_json(200, current)

        elif path == '/api/status':
            data = self.read_body()
            mode = str(data.get('mode', 'unknown'))
            if mode not in ('video', 'gallery', 'unknown'):
                mode = 'unknown'
            status = {
                'mode':           mode,
                'next_switch_in': max(0, int(data.get('next_switch_in', 0)))
            }
            write_json(STATUS_FILE, status)
            self.send_json(200, status)

        else:
            self.send_json(404, {'error': 'Not found'})


# ── Einstiegspunkt ───────────────────────────────────────────────────────────

if __name__ == '__main__':
    # Settings-Datei anlegen falls nicht vorhanden
    if not os.path.exists(SETTINGS_FILE):
        write_json(SETTINGS_FILE, DEFAULT_SETTINGS)

    server = HTTPServer(('127.0.0.1', PORT), Handler)
    print(f'Fotobox API läuft auf http://127.0.0.1:{PORT}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nAPI gestoppt.')
