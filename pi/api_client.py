"""
API client for Formula Helper cloud backend.
Replaces local file I/O with HTTP calls to the serverless API.
Caches last known state for offline resilience.
"""

import json
import os
import threading
import time
import urllib.parse
import urllib.request

CLOUD_API = "https://d20oyc88hlibbe.cloudfront.net"
PI_API_KEY = "XC3DYLpw4SE0VUb4zvfyLypu3b9eQhnntqkGG_amsAw"
_APP_DIR = os.path.dirname(os.path.abspath(__file__))
_CACHE_FILE = os.path.join(_APP_DIR, "state_cache.json")
_lock = threading.Lock()

# Cached state from last successful poll
_cached_state = {
    "mix_log": [],
    "settings": {"countdown_secs": 3900, "ss_timeout_min": 2},
    "countdown_end": 0.0,
    "mixed_at_str": "",
    "mixed_ml": 0,
    "remaining_secs": 0,
    "expired": False,
    "ntfy_sent": False,
    "combos": [],
    "powder_per_60": 8.3,
}
_online = True


def _api_request(path, method="GET", data=None, timeout=10):
    """Make an API request. Returns parsed JSON or None on failure."""
    global _online
    try:
        url = CLOUD_API + path
        headers = {"X-Api-Key": PI_API_KEY}
        if data is not None:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
            req = urllib.request.Request(url, data=body, headers=headers, method=method)
        else:
            req = urllib.request.Request(url, headers=headers, method=method)
        resp = urllib.request.urlopen(req, timeout=timeout)
        _online = True
        return json.loads(resp.read())
    except Exception:
        _online = False
        return None


def _save_cache():
    """Persist cached state to disk for offline startup."""
    try:
        with open(_CACHE_FILE, "w") as f:
            json.dump(_cached_state, f)
    except Exception:
        pass


def _load_cache():
    """Load cached state from disk."""
    global _cached_state
    try:
        with open(_CACHE_FILE, "r") as f:
            _cached_state = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        pass


def is_online():
    return _online


def poll_state():
    """Fetch full state from the API. Returns the state dict."""
    global _cached_state
    result = _api_request("/api/state")
    if result and "mix_log" in result:
        with _lock:
            _cached_state = result
        _save_cache()
    return _cached_state


def get_state():
    """Return the last known state (cached)."""
    with _lock:
        return dict(_cached_state)


def get_log():
    """Return the cached log entries."""
    with _lock:
        return list(_cached_state.get("mix_log", []))


def get_settings():
    """Return the cached settings."""
    with _lock:
        return dict(_cached_state.get("settings", {"countdown_secs": 3900, "ss_timeout_min": 2}))


def get_timer():
    """Return timer state from cache."""
    with _lock:
        return {
            "countdown_end": _cached_state.get("countdown_end", 0.0),
            "mixed_at_str": _cached_state.get("mixed_at_str", ""),
            "mixed_ml": _cached_state.get("mixed_ml", 0),
            "remaining_secs": _cached_state.get("remaining_secs", 0),
            "expired": _cached_state.get("expired", False),
            "ntfy_sent": _cached_state.get("ntfy_sent", False),
        }


def start_timer(ml):
    """Start a new bottle timer. Returns the API response or None."""
    result = _api_request("/api/start", method="POST", data={"ml": ml})
    if result and result.get("ok"):
        # Immediately poll to update cache
        poll_state()
    return result


def delete_log_entry(sk):
    """Delete a log entry by sort key."""
    encoded = urllib.parse.quote(sk, safe="")
    result = _api_request(f"/api/log/{encoded}", method="DELETE")
    if result and result.get("ok"):
        poll_state()
    return result


def edit_log_entry(sk, updates):
    """Edit a log entry. updates is a dict with text/leftover/ml/date fields."""
    encoded = urllib.parse.quote(sk, safe="")
    result = _api_request(f"/api/log/{encoded}", method="PUT", data=updates)
    if result and result.get("ok"):
        poll_state()
    return result


def reset_timer():
    """Reset the countdown timer."""
    result = _api_request("/api/reset-timer", method="POST")
    if result and result.get("ok"):
        poll_state()
    return result


def save_settings(settings):
    """Update settings."""
    result = _api_request("/api/settings", method="POST", data=settings)
    if result and result.get("ok"):
        poll_state()
    return result


def start_timer_async(ml):
    """Start timer in a background thread (non-blocking for UI)."""
    threading.Thread(target=start_timer, args=(ml,), daemon=True).start()


def delete_log_entry_async(sk):
    """Delete in background thread."""
    threading.Thread(target=delete_log_entry, args=(sk,), daemon=True).start()


def init():
    """Initialize — load cache from disk, then do first poll."""
    _load_cache()
    poll_state()
