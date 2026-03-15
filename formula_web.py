#!/usr/bin/env python3
"""
Web interface for the baby formula mixing assistant.
Shares state with the pygame app via JSON files.

Usage:
    python formula_web.py          # binds to 0.0.0.0:5000
    python formula_web.py --port 8080
"""

import argparse
import time
from datetime import datetime

from flask import Flask, jsonify, render_template, request

from formula_app import (
    COMBOS,
    DEFAULT_COUNTDOWN_MIN,
    POWDER_PER_60ML,
    load_backup_status,
    load_log,
    load_settings,
    load_state,
    save_log,
    save_settings,
    save_state,
    send_ntfy,
)

app = Flask(__name__)


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/state")
def api_state():
    state = load_state()
    settings = load_settings()
    mix_log = load_log()

    countdown_end = state.get("countdown_end", 0.0)
    ntfy_sent = state.get("ntfy_sent", False)
    mixed_at_str = state.get("mixed_at_str", "")
    mixed_ml = state.get("mixed_ml", 0)

    remaining = max(0.0, countdown_end - time.time()) if countdown_end > 0 else -1
    expired = countdown_end > 0 and remaining <= 0

    # Send ntfy if just expired and not yet sent
    if expired and not ntfy_sent and countdown_end > 0:
        ntfy_sent = True
        save_state(countdown_end, mixed_at_str, mixed_ml, ntfy_sent)
        send_ntfy("Formula has expired — discard the milk!", mixed_at=mixed_at_str)

    return jsonify(
        countdown_end=countdown_end,
        mixed_at_str=mixed_at_str,
        mixed_ml=mixed_ml,
        remaining_secs=max(0, remaining),
        expired=expired,
        ntfy_sent=ntfy_sent,
        mix_log=mix_log,
        settings=settings,
        combos=[[w, round(p, 2)] for w, p in COMBOS],
        powder_per_60=POWDER_PER_60ML,
        backup_status=load_backup_status(),
    )


@app.route("/api/start", methods=["POST"])
def api_start():
    data = request.get_json(force=True)
    ml = int(data.get("ml", 60))
    settings = load_settings()
    countdown_secs = settings.get("countdown_secs", DEFAULT_COUNTDOWN_MIN * 60)

    countdown_end = time.time() + countdown_secs
    mixed_at_str = datetime.now().strftime("%I:%M %p")

    mix_log = load_log()
    mix_log.append({"text": f"{ml}ml @ {mixed_at_str}", "leftover": "",
                    "ml": ml, "date": datetime.now().strftime("%Y-%m-%d %I:%M %p")})
    save_log(mix_log)
    save_state(countdown_end, mixed_at_str, ml, False)

    return jsonify(ok=True)


@app.route("/api/log/<int:idx>", methods=["PUT"])
def api_log_edit(idx):
    data = request.get_json(force=True)
    mix_log = load_log()
    if idx < 0 or idx >= len(mix_log):
        return jsonify(ok=False, error="invalid index"), 400
    entry = mix_log[idx]
    # Normalize old string entries to dict
    if isinstance(entry, str):
        entry = {"text": entry, "leftover": ""}
    if "text" in data:
        entry["text"] = data["text"]
    if "leftover" in data:
        entry["leftover"] = data["leftover"]
    mix_log[idx] = entry
    save_log(mix_log)
    return jsonify(ok=True)


@app.route("/api/log/<int:idx>", methods=["DELETE"])
def api_log_delete(idx):
    mix_log = load_log()
    if idx < 0 or idx >= len(mix_log):
        return jsonify(ok=False, error="invalid index"), 400
    mix_log.pop(idx)
    save_log(mix_log)
    return jsonify(ok=True)


@app.route("/api/reset-timer", methods=["POST"])
def api_reset_timer():
    save_state(0.0, "", 0, False)
    return jsonify(ok=True)


@app.route("/api/settings", methods=["POST"])
def api_settings():
    data = request.get_json(force=True)
    settings = load_settings()
    if "countdown_secs" in data:
        settings["countdown_secs"] = int(data["countdown_secs"])
    if "ss_timeout_min" in data:
        settings["ss_timeout_min"] = int(data["ss_timeout_min"])
    save_settings(settings)
    return jsonify(ok=True, settings=settings)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Formula Helper Web UI")
    parser.add_argument("--port", "-p", type=int, default=5000)
    args = parser.parse_args()
    app.run(host="0.0.0.0", port=args.port, debug=False)
