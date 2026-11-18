#!/usr/bin/env python3
"""Tiny stdlib load generator for the Open WebUI chat API.

Sends concurrent POST /api/chat/completions requests for a fixed duration and
writes a JSON summary (RPS, latency percentiles, status/error breakdown).

Example:
  python3 gen.py --url http://<LB-IP>/api/chat/completions --token <JWT> \
      --concurrency 12 --duration 240 --max-tokens 16 --out phase.json
"""
import argparse
import json
import threading
import time
import urllib.error
import urllib.request


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--token", required=True)
    p.add_argument("--model", default="Qwen/Qwen2.5-0.5B-Instruct")
    p.add_argument("--concurrency", type=int, default=4)
    p.add_argument("--duration", type=int, default=180, help="seconds")
    p.add_argument("--max-tokens", type=int, default=16)
    p.add_argument("--prompt", default="hi")
    p.add_argument("--timeout", type=float, default=120.0, help="per-request client timeout (s)")
    p.add_argument("--out", required=True, help="output JSON file")
    a = p.parse_args()

    body = json.dumps({
        "model": a.model,
        "messages": [{"role": "user", "content": a.prompt}],
        "max_tokens": a.max_tokens,
    }).encode()

    results = []
    lock = threading.Lock()
    stop_at = time.time() + a.duration

    def worker():
        while time.time() < stop_at:
            t0 = time.time()
            code, err = 0, ""
            try:
                req = urllib.request.Request(a.url, data=body, method="POST", headers={
                    "Authorization": "Bearer " + a.token,
                    "Content-Type": "application/json",
                })
                with urllib.request.urlopen(req, timeout=a.timeout) as r:
                    r.read()
                    code = r.status
            except urllib.error.HTTPError as e:
                code, err = e.code, "http"
                try:
                    e.read()
                except Exception:
                    pass
            except Exception as e:
                code, err = 0, type(e).__name__  # e.g. TimeoutError (LB idle cutoff)
            with lock:
                results.append((time.time() - t0, code, err))

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(a.concurrency)]
    t0 = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.time() - t0

    lat = sorted(r[0] for r in results)

    def pct(q):
        return lat[min(len(lat) - 1, int(q * len(lat)))] if lat else 0.0

    summary = {
        "url": a.url,
        "concurrency": a.concurrency,
        "duration_s": round(wall, 1),
        "requests": len(results),
        "ok": sum(1 for r in results if r[1] == 200),
        "errors": sum(1 for r in results if r[1] != 200),
        "rps": round(len(results) / wall, 2) if wall else 0,
        "latency_s": {"p50": round(pct(0.5), 2), "p95": round(pct(0.95), 2),
                      "p99": round(pct(0.99), 2), "max": round(lat[-1], 2) if lat else 0},
        "status_counts": {},
        "error_breakdown": {},
    }
    for r in results:
        summary["status_counts"][str(r[1])] = summary["status_counts"].get(str(r[1]), 0) + 1
        if r[1] != 200:
            summary["error_breakdown"][r[2]] = summary["error_breakdown"].get(r[2], 0) + 1

    with open(a.out, "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
