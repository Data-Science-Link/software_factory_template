# Minimal OpenAI-compatible chat.completions mock (streaming) used once to capture the real
# OpenCode 1.19.5 usage formats in this folder offline (#30 part 1). Fixed, made-up token counts;
# no real model, no key. Session 1 = requests 0-2, session 2 = requests 3-5. See README.md.
import json, time, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
N=[0]
USAGE=[{"prompt_tokens":1200,"completion_tokens":80,"total_tokens":1280,"prompt_tokens_details":{"cached_tokens":1000}},
       {"prompt_tokens":1500,"completion_tokens":40,"total_tokens":1540,"prompt_tokens_details":{"cached_tokens":1200}}]
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): sys.stderr.write("req %s\n" % self.path)
    def do_GET(self):
        self.send_response(200); self.send_header("content-type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({"object":"list","data":[{"id":"Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo","object":"model"}]}).encode())
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers.get("content-length",0))) or b"{}")
        open("requests.log","a").write(json.dumps({k:body.get(k) for k in ("model","stream","stream_options")})+"\n")
        i=N[0]; N[0]+=1
        u={"prompt_tokens":1000+500*i,"completion_tokens":30+10*i,"total_tokens":1030+510*i,"prompt_tokens_details":{"cached_tokens":800+400*i}}
        has_tools=bool(body.get("tools")); msgs=body.get("messages") or []
        want_tool=has_tools and not any(m.get("role")=="tool" for m in msgs)
        text="Mock reply %d: hello." % i
        mid="chatcmpl-mock%d" % i; created=int(time.time())
        if body.get("stream"):
            self.send_response(200); self.send_header("content-type","text/event-stream"); self.end_headers()
            if want_tool:
                tc={"index":0,"id":"call_mock%d"%i,"type":"function","function":{"name":"read","arguments":json.dumps({"filePath":"README.md"})}}
                chunks=[{"id":mid,"object":"chat.completion.chunk","created":created,"model":body.get("model"),"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[tc]},"finish_reason":None}]},
                        {"id":mid,"object":"chat.completion.chunk","created":created,"model":body.get("model"),"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]},
                        {"id":mid,"object":"chat.completion.chunk","created":created,"model":body.get("model"),"choices":[],"usage":u}]
                for c in chunks: self.wfile.write(("data: "+json.dumps(c)+"\n\n").encode())
                self.wfile.write(b"data: [DONE]\n\n"); return
            chunks=[{"id":mid,"object":"chat.completion.chunk","created":created,"model":body.get("model"),"choices":[{"index":0,"delta":{"role":"assistant","content":text},"finish_reason":None}]},
                    {"id":mid,"object":"chat.completion.chunk","created":created,"model":body.get("model"),"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]},
                    {"id":mid,"object":"chat.completion.chunk","created":created,"model":body.get("model"),"choices":[],"usage":u}]
            for c in chunks: self.wfile.write(("data: "+json.dumps(c)+"\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            self.send_response(200); self.send_header("content-type","application/json"); self.end_headers()
            self.wfile.write(json.dumps({"id":mid,"object":"chat.completion","created":created,"model":body.get("model"),"choices":[{"index":0,"message":{"role":"assistant","content":text},"finish_reason":"stop"}],"usage":u}).encode())
HTTPServer(("127.0.0.1",18555),H).serve_forever()
