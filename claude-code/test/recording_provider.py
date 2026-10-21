"""Stand-in for the Anthropic API that records every request Claude Code sends.

Usage: recording_provider.py <requests dir> <port file> [bash command]
Each POST body is saved as <requests dir>/<n>.json and answered with a
one-line streamed reply. Given a bash command, a request that offers the Bash
tool and carries no tool result yet is answered with a call running that
command instead, so the turn exercises Claude Code's permission checks. The
listening port is written to <port file> once the socket is bound, so the
caller can wait for that file to appear.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUESTS_DIR = sys.argv[1]
PORT_FILE = sys.argv[2]
BASH_COMMAND = sys.argv[3] if len(sys.argv) > 3 else None


def streamed_reply(content_block, delta, stop_reason):
    return [
        ("message_start", {"type": "message_start", "message": {
            "id": "msg_fixture", "type": "message", "role": "assistant", "model": "fixture",
            "content": [], "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 1, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0,
                                 "content_block": content_block}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": delta}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta",
                           "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                           "usage": {"output_tokens": 4}}),
        ("message_stop", {"type": "message_stop"}),
    ]


TEXT_REPLY = streamed_reply(
    {"type": "text", "text": ""},
    {"type": "text_delta", "text": "Local fixture answer."},
    "end_turn")


def bash_call_reply(command):
    arguments = {"command": command, "description": "Fixture command"}
    return streamed_reply(
        {"type": "tool_use", "id": "toolu_fixture", "name": "Bash", "input": {}},
        {"type": "input_json_delta", "partial_json": json.dumps(arguments)},
        "tool_use")


def wants_bash_call(body):
    offers_bash = any(tool.get("name") == "Bash" for tool in body.get("tools", []))
    return offers_bash and "tool_result" not in json.dumps(body.get("messages", []))


class RecordingHandler(BaseHTTPRequestHandler):
    request_count = 0

    def log_message(self, format, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
        RecordingHandler.request_count += 1
        record_path = os.path.join(REQUESTS_DIR, f"{RecordingHandler.request_count:03d}.json")
        with open(record_path, "w") as record:
            json.dump({"path": self.path, "body": body}, record)
        reply = TEXT_REPLY
        if BASH_COMMAND is not None and wants_bash_call(body):
            reply = bash_call_reply(BASH_COMMAND)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        for event, data in reply:
            self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())


os.makedirs(REQUESTS_DIR, exist_ok=True)
server = ThreadingHTTPServer(("127.0.0.1", 0), RecordingHandler)
with open(PORT_FILE + ".partial", "w") as port_file:
    port_file.write(str(server.server_address[1]))
os.rename(PORT_FILE + ".partial", PORT_FILE)
server.serve_forever()
