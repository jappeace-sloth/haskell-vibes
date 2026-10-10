"""Stand-in for the Anthropic API that records every request Claude Code sends.

Usage: recording_provider.py <requests dir> <port file>
Each POST body is saved as <requests dir>/<n>.json and answered with a
one-line streamed reply. The listening port is written to <port file> once
the socket is bound, so the caller can wait for that file to appear.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUESTS_DIR = sys.argv[1]
PORT_FILE = sys.argv[2]

STREAMED_REPLY = [
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_fixture", "type": "message", "role": "assistant", "model": "fixture",
        "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": 1, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                             "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": "Local fixture answer."}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                       "usage": {"output_tokens": 4}}),
    ("message_stop", {"type": "message_stop"}),
]


class RecordingHandler(BaseHTTPRequestHandler):
    request_count = 0

    def log_message(self, format, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        RecordingHandler.request_count += 1
        record_path = os.path.join(REQUESTS_DIR, f"{RecordingHandler.request_count:03d}.json")
        with open(record_path, "w") as record:
            json.dump({"path": self.path, "body": json.loads(body)}, record)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        for event, data in STREAMED_REPLY:
            self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())


os.makedirs(REQUESTS_DIR, exist_ok=True)
server = ThreadingHTTPServer(("127.0.0.1", 0), RecordingHandler)
with open(PORT_FILE + ".partial", "w") as port_file:
    port_file.write(str(server.server_address[1]))
os.rename(PORT_FILE + ".partial", PORT_FILE)
server.serve_forever()
