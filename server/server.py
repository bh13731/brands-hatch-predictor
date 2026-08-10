#!/usr/bin/env python3
"""Caterham Academy prediction game API (Knockhill: quali + race1 + race2).
Stdlib only, JSON file store."""
import json, os, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.join(BASE, "..", "data", "store.json")
DRIVERS = os.path.join(BASE, "..", "data", "drivers.json")
ADMIN_KEY = os.environ.get("PREDICTOR_ADMIN_KEY", "changeme")
LOCK = threading.Lock()

SESSIONS = ("quali", "race1", "race2")

DEFAULT_STORE = {
    "event": "Caterham Academy — Knockhill, Sat 15–Sun 16 Aug 2026",
    "lock_at": "2026-08-15T06:00:00Z",  # predictions lock (UTC) = 07:00 UK Sat, pre-quali
    # name -> {pin, submitted_at, updated_at, sessions:{quali:[10], race1:[10], race2:[10]}}
    "predictions": {},
    # per-session finishing order (list of driver names) once entered, else None
    "results": {"quali": None, "race1": None, "race2": None},
}

def load_store():
    try:
        with open(STORE) as f:
            return json.load(f)
    except Exception:
        return json.loads(json.dumps(DEFAULT_STORE))

def save_store(s):
    tmp = STORE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=1)
    os.replace(tmp, STORE)

def load_drivers():
    with open(DRIVERS) as f:
        return json.load(f)["drivers"]

def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def any_results(s):
    r = s.get("results") or {}
    return any(r.get(k) for k in SESSIONS)

def locked(s):
    return bool(now_iso() >= s["lock_at"] or any_results(s))

def score(pred, results):
    """Lower = better. Sum over 10 picks of |predicted_pos - actual_pos|.
    Driver missing from results (DNF/DNS) counts as position len(results)+3."""
    idx = {n: i + 1 for i, n in enumerate(results)}
    miss = len(results) + 3
    total, exact = 0, 0
    for p, name in enumerate(pred, start=1):
        a = idx.get(name, miss)
        total += abs(p - a)
        if p == a:
            exact += 1
    return total, exact

def build_leaderboard(s):
    lb = []
    for name, p in s["predictions"].items():
        scores, total, exact = {}, 0, 0
        for k in SESSIONS:
            res = (s.get("results") or {}).get(k)
            pred = (p.get("sessions") or {}).get(k)
            if res and pred:
                t, e = score(pred, res)
                scores[k] = t
                total += t
                exact += e
            else:
                scores[k] = None
        lb.append({"name": name, "scores": scores, "total": total, "exact": exact})
    lb.sort(key=lambda r: (r["total"], -r["exact"], r["name"].lower()))
    return lb

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(200, {})

    def do_GET(self):
        if self.path.startswith("/api/state"):
            with LOCK:
                s = load_store()
            drivers = load_drivers()
            is_locked = locked(s)
            preds = {}
            for name, p in s["predictions"].items():
                if is_locked:
                    preds[name] = {"sessions": p["sessions"], "updated_at": p["updated_at"]}
                else:
                    preds[name] = {"updated_at": p["updated_at"]}  # hide picks until lock
            out = {
                "event": s["event"], "lock_at": s["lock_at"], "locked": is_locked,
                "drivers": drivers, "predictions": preds, "results": s.get("results"),
                "server_time": now_iso(),
            }
            if any_results(s):
                out["leaderboard"] = build_leaderboard(s)
            self._send(200, out)
        elif self.path == "/api/health":
            self._send(200, {"ok": True, "time": now_iso()})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})

        if self.path == "/api/predict":
            name = str(data.get("name", "")).strip()[:40]
            pin = str(data.get("pin", "")).strip()[:20]
            sessions = data.get("sessions")
            if not re.match(r"^[\w \-'.]{2,40}$", name):
                return self._send(400, {"error": "Enter a valid name (2-40 chars)."})
            if not pin or len(pin) < 3:
                return self._send(400, {"error": "PIN must be at least 3 characters."})
            valid = {d["name"] for d in load_drivers()}
            if not isinstance(sessions, dict):
                return self._send(400, {"error": "Missing sessions."})
            labels = {"quali": "Quali", "race1": "Race 1", "race2": "Race 2"}
            clean = {}
            for k in SESSIONS:
                lst = sessions.get(k)
                if (not isinstance(lst, list) or len(lst) != 10
                        or len(set(lst)) != 10 or any(t not in valid for t in lst)):
                    return self._send(400, {"error": f"{labels[k]}: pick exactly 10 distinct drivers."})
                clean[k] = lst
            with LOCK:
                s = load_store()
                if locked(s):
                    return self._send(403, {"error": "Predictions are locked."})
                key = name.lower()
                existing = next((k for k in s["predictions"] if k.lower() == key), None)
                if existing:
                    if s["predictions"][existing]["pin"] != pin:
                        return self._send(403, {"error": "Name taken — wrong PIN. Use your PIN to update your picks."})
                    s["predictions"][existing].update(sessions=clean, updated_at=now_iso())
                else:
                    s["predictions"][name] = {"sessions": clean, "pin": pin,
                                              "submitted_at": now_iso(), "updated_at": now_iso()}
                save_store(s)
            return self._send(200, {"ok": True})

        if self.path == "/api/admin/results":
            if data.get("key") != ADMIN_KEY:
                return self._send(403, {"error": "bad key"})
            sess = data.get("session")
            if sess not in SESSIONS:
                return self._send(400, {"error": "session must be quali|race1|race2"})
            order = data.get("order")
            valid = {d["name"] for d in load_drivers()}
            if order is not None and (not isinstance(order, list) or len(set(order)) != len(order)
                                      or any(o not in valid for o in order)):
                return self._send(400, {"error": "invalid order"})
            with LOCK:
                s = load_store()
                if not isinstance(s.get("results"), dict):
                    s["results"] = {k: None for k in SESSIONS}
                s["results"][sess] = order
                save_store(s)
            return self._send(200, {"ok": True})

        if self.path == "/api/admin/lock":
            if data.get("key") != ADMIN_KEY:
                return self._send(403, {"error": "bad key"})
            with LOCK:
                s = load_store()
                if "lock_at" in data:
                    s["lock_at"] = data["lock_at"]
                save_store(s)
            return self._send(200, {"ok": True, "lock_at": load_store()["lock_at"]})

        self._send(404, {"error": "not found"})

if __name__ == "__main__":
    if not os.path.exists(STORE):
        save_store(json.loads(json.dumps(DEFAULT_STORE)))
    port = int(os.environ.get("PORT", 8790))
    print(f"listening on :{port}")
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
