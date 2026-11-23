"""Minimal CodeSonar hub for the tests: mock_hub.py PORT_FILE SARIF_FILE [SOURCE_DIR]

Implements the endpoints the plugin uses, with user "lspuser" and
password "secret". Requests are logged to PORT_FILE.log.
"""
import base64, json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, sarif_file = sys.argv[1], sys.argv[2]
source_dir = sys.argv[3] if len(sys.argv) > 3 else None
SOURCES = {"10000001.0": "main.c", "10000002.0": "utils.c"}


def listing(name):
    """A file listing as the hub returns it: lines split into tokens."""
    children = [{"type": "wdom_file", "name": "/build/test_project/" + name}]
    with open(os.path.join(source_dir, name)) as source:
        for number, line in enumerate(source, 1):
            text = line.rstrip("\n")
            half = len(text) // 2
            children.append({"type": "wdom_line", "number": number, "children": [
                {"type": "wdom_s", "children": [{"type": "wdom_c", "children": [text[:half]]}]},
                {"type": "wdom_s", "comment": True, "children": [text[half:], "\n"]},
            ]})
    return {"type": "wdom_file", "children": children}
# The categories of warning 305, a double free, as the hub returns them.
DOUBLE_FREE_RULES = [
    {"link": "ALLOC.DF", "url": "/install/codesonar/doc/html/ALLOC.DF.html",
     "relationship": None, "rule_text": None},
    {"link": "MisraC2025:D.4.1", "url": "/install/codesonar/doc/html/MISRA_C.html",
     "relationship": "intersects", "rule_text": "Run-time failures shall be minimized"},
    {"link": "CWE:415", "url": "https://links.codesonar.com/cwe/id/415/",
     "relationship": "intersects", "rule_text": "Double Free"},
    {"link": "CERT-CPP:OOP54-CPP", "url": "https://links.codesonar.com/cert-cpp/",
     "relationship": "follows", "rule_text": "Gracefully handle self-copy assignment"},
]
# The analyses of project test_project, which the tests may delete.
ANALYSES = [
    {"analysis": "test_project initial", "started": "2026-11-09T22:28:29Z",
     "state": "DAEMON", "url": "/analysis/3.json"},
    {"analysis": "test_project running", "started": "2026-11-09T23:00:00Z",
     "state": "ANALYZING", "url": "/analysis/5.json"},
    {"analysis": "test_project fixes", "started": "2026-11-09T22:40:40Z",
     "state": "FINISHED", "url": "/analysis/4.json"},
]
# The state and finding of warnings, by instance id, once they were changed.
TRIAGE = {}
TOKEN = "4/token"
expired = {"once": False}


class Hub(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, kind="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log(self):
        with open(port_file + ".log", "a") as log:
            log.write(f"{self.command} {self.path} {self.headers.get('Authorization', '')}\n")

    def do_POST(self):
        self.log()
        length = int(self.headers.get("Content-Length", 0))
        form = self.rfile.read(length).decode()
        if self.path == "/project/2.json" and "remove_analysis_id=" in form:
            return self.delete_analysis(form)
        if self.path.startswith("/warninginstance/"):
            return self.change_warning(form)
        if self.path != "/session/create-basic-auth/" or "key=bearer" not in form:
            return self.reply(404, "Not Found", "text/plain")
        expected = "Basic " + base64.b64encode(b"lspuser:secret").decode()
        if self.headers.get("Authorization") != expected:
            return self.reply(403, json.dumps(
                {"status": 403, "error": "Permission Denied: Invalid user name or password."}))
        self.reply(200, json.dumps({"bearer": TOKEN, "user": {"name": "lspuser"}}))

    def delete_analysis(self, form):
        """Deletes like the form of the project page, but lspuser may not
        delete analysis 4."""
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.reply(403, json.dumps({"status": 403, "error": "Permission Denied"}))
        analysis_id = int(form.split("remove_analysis_id=")[1].split("&")[0])
        if analysis_id == 4:
            return self.reply(403, json.dumps({"status": 403, "error": "Permission Denied"}))
        ANALYSES[:] = [row for row in ANALYSES if row["url"] != f"/analysis/{analysis_id}.json"]
        self.reply(200, json.dumps({"change": {"results": [{
            "action": "remove_analysis", "item": {"type": "analysis", "id": analysis_id},
            "result": "success", "message": "Removed"}]}}))

    def change_warning(self, form):
        """Changes a warning like its page, but lspuser may only change
        states, not findings."""
        if self.headers.get("Authorization") != "Bearer " + TOKEN or "sel_finding=" in form:
            return self.reply(403, json.dumps({"status": 403, "error": "Permission Denied"}))
        instance = self.path[len("/warninginstance/"):-len(".json")]
        fields = urllib.parse.parse_qs(form)
        state = json.loads(fields["sel_state"][0])
        TRIAGE[instance] = {"state": {"id": 3, "label": state}}
        self.reply(200, json.dumps(self.warning(instance)))

    def warning(self, instance):
        warning = {"id": int(instance), "group": TRIAGE.get(instance, {})}
        if instance == "305":
            warning["categories"] = DOUBLE_FREE_RULES
        return warning

    def do_GET(self):
        self.log()
        if self.path == "/expire-session":
            expired["once"] = True
            return self.reply(200, "{}")
        if self.headers.get("Authorization") != "Bearer " + TOKEN or expired["once"]:
            expired["once"] = False
            return self.reply(403, json.dumps({"status": 403, "error": "Permission Denied"}))
        if self.path == "/project_search.json":
            return self.reply(200, json.dumps({"rows": [
                {"project": "mixxx", "url": "/project/1.json"},
                {"project": "test_project", "url": "/project/2.json"},
            ]}))
        if self.path == "/project/2.json":
            return self.reply(200, json.dumps({"rows": ANALYSES}))
        analysis = next((row for row in ANALYSES if row["url"] == self.path), None)
        if analysis:
            return self.reply(200, json.dumps({
                "id": int(self.path[len("/analysis/"):-len(".json")]), "name": analysis["analysis"],
                "state": analysis["state"], "project": {"id": 2, "name": "test_project"}}))
        if self.path in ("/analysis/3-allwarnings.sarif", "/analysis/4-allwarnings.sarif"):
            return self.reply(200, open(sarif_file, "rb").read(), "application/sarif+json")
        if self.path == "/analysis/3-files.json" and source_dir:
            return self.reply(200, json.dumps({"id": 3, "rows": [
                {"file": name, "url": f"/analysis/3-file{sfid}.json"} for sfid, name in SOURCES.items()
            ]}))
        if self.path.startswith("/analysis/3-file") and source_dir:
            sfid = self.path[len("/analysis/3-file"):-len(".json")]
            if sfid in SOURCES:
                return self.reply(200, json.dumps(listing(SOURCES[sfid])))
        instance = self.path[len("/warninginstance/"):-len(".json")]
        if self.path.startswith("/warninginstance/") and (instance == "305" or instance in TRIAGE):
            return self.reply(200, json.dumps(self.warning(instance)))
        if self.path == "/analysis/9-allwarnings.sarif":
            return self.reply(200, "<html>oops</html>", "text/html")
        self.reply(404, "Analysis not found", "text/plain")


server = HTTPServer(("127.0.0.1", 0), Hub)
with open(port_file, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
