#!/usr/bin/env python3
"""
Baby formula mixing assistant — static reference card + expiry timer.
Raspberry Pi + 800×480 touchscreen display.

Usage:
    python formula_app.py                # windowed
    python formula_app.py --fullscreen   # fullscreen (recommended on RPi)
    python formula_app.py --simulate     # windowed dev mode

Controls:
    Q           quit
    Tap "Start Timer" to begin 65-min countdown
"""

import os
import sys
import argparse
import json
import time
import threading
import urllib.parse
import urllib.request
from datetime import datetime
from enum import Enum, auto
import api_client

# ── Allow framebuffer rendering on RPi without a desktop ─────────────────────
if not os.environ.get("DISPLAY") and sys.platform != "darwin":
    os.environ.setdefault("SDL_VIDEODRIVER", "fbcon")
    os.environ.setdefault("SDL_FBDEV", "/dev/fb0")
    os.environ.setdefault("SDL_MOUSEDRV", "TSLIB")
    os.environ.setdefault("SDL_MOUSEDEV", "/dev/input/touchscreen")

import pygame

# ── Formula combos ───────────────────────────────────────────────────────────
POWDER_PER_60ML = 8.3  # grams of powder per 60 ml water

COMBOS = [
    (60,  POWDER_PER_60ML * 60  / 60.0),
    (80,  POWDER_PER_60ML * 80  / 60.0),
    (90,  POWDER_PER_60ML * 90  / 60.0),
    (100, POWDER_PER_60ML * 100 / 60.0),
]

# ── Countdown parameters ────────────────────────────────────────────────────
COUNTDOWN_SECS = 10        # TESTING: 10 seconds (overridden by settings)
WARN_SECS      = 10 * 60   # last 10 min: background turns red
NTFY_TOPIC     = "bottle-expiry-1737"


def send_ntfy(msg: str, title: str = "Formula Expired", mixed_at: str = "") -> None:
    """Send push notification via ntfy.sh in a background thread."""
    def _send():
        try:
            ntfy_title = f"Formula mixed at {mixed_at} has expired" if mixed_at else title
            req = urllib.request.Request(
                f"https://ntfy.sh/{NTFY_TOPIC}",
                data=msg.encode(),
                headers={"Title": ntfy_title, "Priority": "high", "Tags": "baby_bottle"},
            )
            urllib.request.urlopen(req, timeout=10)
        except Exception:
            pass
    threading.Thread(target=_send, daemon=True).start()

_APP_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(_APP_DIR, "mix_log.json")
SETTINGS_FILE = os.path.join(_APP_DIR, "settings.json")
STATE_FILE = os.path.join(_APP_DIR, "countdown_state.json")

DEFAULT_COUNTDOWN_MIN = 65


def load_settings() -> dict:
    try:
        with open(SETTINGS_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"countdown_min": DEFAULT_COUNTDOWN_MIN}


def save_settings(settings: dict) -> None:
    try:
        with open(SETTINGS_FILE, "w") as f:
            json.dump(settings, f)
    except Exception:
        pass



def load_state() -> dict:
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(countdown_end: float, mixed_at_str: str, mixed_ml: int, ntfy_sent: bool) -> None:
    try:
        with open(STATE_FILE, "w") as f:
            json.dump({
                "countdown_end": countdown_end,
                "mixed_at_str": mixed_at_str,
                "mixed_ml": mixed_ml,
                "ntfy_sent": ntfy_sent,
            }, f)
    except Exception:
        pass


def load_log() -> list:
    try:
        with open(LOG_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


BACKUP_URL = "https://xwp91fa14g.execute-api.us-east-1.amazonaws.com/prod/backup"
BACKUP_STATUS_FILE = os.path.join(_APP_DIR, "backup_status.json")
WEEKLY_NTFY_FILE = os.path.join(_APP_DIR, "weekly_ntfy_state.json")


def load_backup_status() -> dict:
    try:
        with open(BACKUP_STATUS_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_backup_status(ok: bool, error: str = "") -> None:
    try:
        with open(BACKUP_STATUS_FILE, "w") as f:
            json.dump({
                "ok": ok,
                "time": datetime.now().strftime("%I:%M %p"),
                "error": error,
            }, f)
    except Exception:
        pass


def _backup_to_s3(mix_log: list) -> None:
    """Send log to S3 via API Gateway in a background thread."""
    def _send():
        try:
            data = json.dumps({"log": mix_log}).encode()
            req = urllib.request.Request(
                BACKUP_URL, data=data,
                headers={"Content-Type": "application/json"},
            )
            urllib.request.urlopen(req, timeout=10)
            _save_backup_status(True)
        except Exception as e:
            _save_backup_status(False, str(e))
    threading.Thread(target=_send, daemon=True).start()


# ── Weekly insights & notification ────────────────────────────────────────
def _compute_weekly_insights(mix_log: list) -> dict:
    """Compute this week vs last week consumption stats."""
    from datetime import timedelta
    now = datetime.now()
    # Monday of this week at 00:00
    this_monday = (now - timedelta(days=now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0)
    last_monday = this_monday - timedelta(days=7)

    this_week = {"total_ml": 0, "bottles": 0, "days": set()}
    last_week = {"total_ml": 0, "bottles": 0, "days": set()}

    for e in mix_log:
        if not isinstance(e, dict) or not e.get("date") or not e.get("ml"):
            continue
        try:
            d = datetime.strptime(e["date"], "%Y-%m-%d %I:%M %p")
        except (ValueError, TypeError):
            continue
        ml = e["ml"]
        day_str = d.strftime("%Y-%m-%d")
        if d >= this_monday:
            this_week["total_ml"] += ml
            this_week["bottles"] += 1
            this_week["days"].add(day_str)
        elif d >= last_monday:
            last_week["total_ml"] += ml
            last_week["bottles"] += 1
            last_week["days"].add(day_str)

    tw_days = max(1, len(this_week["days"]))
    lw_days = max(1, len(last_week["days"]))

    result = {
        "this_week_ml": this_week["total_ml"],
        "this_week_bottles": this_week["bottles"],
        "this_week_avg": round(this_week["total_ml"] / tw_days),
        "last_week_ml": last_week["total_ml"],
        "last_week_bottles": last_week["bottles"],
        "last_week_avg": round(last_week["total_ml"] / lw_days),
    }

    change = this_week["total_ml"] - last_week["total_ml"]
    result["change_ml"] = change
    if last_week["total_ml"] > 0:
        result["change_pct"] = round(change / last_week["total_ml"] * 100)
    else:
        result["change_pct"] = None
    result["avg_change"] = result["this_week_avg"] - result["last_week_avg"]

    return result


def _check_weekly_notification(mix_log: list) -> None:
    """Send weekly summary notification on the first log entry of each new ISO week."""
    def _do_check():
        try:
            current_week = datetime.now().strftime("%G-W%V")
            try:
                with open(WEEKLY_NTFY_FILE, "r") as f:
                    state = json.load(f)
            except (FileNotFoundError, json.JSONDecodeError):
                state = {}

            if state.get("last_sent_week") == current_week:
                return

            insights = _compute_weekly_insights(mix_log)

            # Build message
            lines = []
            tw = insights
            lines.append(f"This week: {tw['this_week_ml']}ml "
                          f"({tw['this_week_bottles']} bottles, "
                          f"avg {tw['this_week_avg']}ml/day)")

            if tw["last_week_ml"] > 0:
                lines.append(f"Last week: {tw['last_week_ml']}ml "
                              f"({tw['last_week_bottles']} bottles, "
                              f"avg {tw['last_week_avg']}ml/day)")
                sign = "+" if tw["change_ml"] >= 0 else ""
                pct = f" ({sign}{tw['change_pct']}%)" if tw["change_pct"] is not None else ""
                avg_sign = "+" if tw["avg_change"] >= 0 else ""
                lines.append(f"Change: {sign}{tw['change_ml']}ml{pct} | "
                              f"Avg/day: {avg_sign}{tw['avg_change']}ml")
            else:
                lines.append("No data from last week to compare.")

            msg = "\n".join(lines)

            req = urllib.request.Request(
                f"https://ntfy.sh/{NTFY_TOPIC}",
                data=msg.encode(),
                headers={
                    "Title": "Weekly Formula Summary",
                    "Priority": "default",
                    "Tags": "chart_with_upwards_trend,baby_bottle",
                },
            )
            urllib.request.urlopen(req, timeout=10)

            with open(WEEKLY_NTFY_FILE, "w") as f:
                json.dump({"last_sent_week": current_week}, f)
        except Exception:
            pass
    threading.Thread(target=_do_check, daemon=True).start()


CLOUD_API = "https://d20oyc88hlibbe.cloudfront.net"


def _sync_start_to_cloud(ml):
    """Notify the cloud API when a bottle is started from the Pi."""
    def _send():
        try:
            data = json.dumps({"ml": ml}).encode()
            req = urllib.request.Request(
                f"{CLOUD_API}/api/start", data=data,
                headers={"Content-Type": "application/json"},
            )
            urllib.request.urlopen(req, timeout=10)
        except Exception:
            pass
    threading.Thread(target=_send, daemon=True).start()


def _sync_delete_to_cloud(entry):
    """Notify the cloud API when a log entry is deleted from the Pi."""
    def _send():
        try:
            # Find matching entry by date
            date_str = entry.get("date", "") if isinstance(entry, dict) else ""
            if not date_str:
                return
            req = urllib.request.Request(f"{CLOUD_API}/api/state")
            resp = urllib.request.urlopen(req, timeout=10)
            state = json.loads(resp.read())
            for e in state.get("mix_log", []):
                if e.get("date") == date_str and e.get("ml") == entry.get("ml"):
                    sk = e.get("sk", "")
                    if sk:
                        dreq = urllib.request.Request(
                            f"{CLOUD_API}/api/log/{urllib.parse.quote(sk, safe='')}",
                            method="DELETE",
                        )
                        urllib.request.urlopen(dreq, timeout=10)
                    break
        except Exception:
            pass
    threading.Thread(target=_send, daemon=True).start()


def save_log(mix_log: list) -> None:
    try:
        with open(LOG_FILE, "w") as f:
            json.dump(mix_log, f)
        _backup_to_s3(mix_log)
        _check_weekly_notification(mix_log)
    except Exception:
        pass


def restore_state_from_log(mix_log: list) -> tuple:
    """After deleting the latest entry, restore timer state from the new latest entry.
    Returns (countdown_end, mixed_at_str, mixed_ml, ntfy_sent)."""
    settings = load_settings()
    countdown_secs = settings.get("countdown_secs", DEFAULT_COUNTDOWN_MIN * 60)

    if not mix_log:
        save_state(0.0, "", 0, False)
        return 0.0, "", 0, False

    # Find the most recent entry (last in list)
    latest = mix_log[-1]
    if not isinstance(latest, dict) or not latest.get("date"):
        save_state(0.0, "", 0, False)
        return 0.0, "", 0, False

    # Parse the entry's datetime to reconstruct countdown_end
    try:
        mixed_dt = datetime.strptime(latest["date"], "%Y-%m-%d %I:%M %p")
        mixed_at_str = mixed_dt.strftime("%I:%M %p")
        mixed_ml = latest.get("ml", 0)
        # Reconstruct when the timer would have ended
        import calendar
        mixed_ts = mixed_dt.timestamp()
        countdown_end = mixed_ts + countdown_secs
        # Check if already expired
        expired = time.time() > countdown_end
        ntfy_sent = expired  # if expired, assume notification was already sent
        save_state(countdown_end, mixed_at_str, mixed_ml, ntfy_sent)
        return countdown_end, mixed_at_str, mixed_ml, ntfy_sent
    except (ValueError, KeyError):
        save_state(0.0, "", 0, False)
        return 0.0, "", 0, False


class AppMode(Enum):
    MAIN        = auto()
    SAMPLES     = auto()
    LOG         = auto()
    CALCULATOR  = auto()
    TRENDS      = auto()
    SCREENSAVER = auto()

SCREENSAVER_TIMEOUT = 2 * 60  # 2 minutes of idle → screensaver

# ── Display geometry ─────────────────────────────────────────────────────────
W, H = 800, 480
FPS  = 30
XPAD = 20
HDR_H = 0  # no header

# ── Palette ──────────────────────────────────────────────────────────────────
C_BG       = (  8,   8,  15)
C_BG2      = ( 14,  14,  26)
C_CARD     = ( 20,  20,  34)
C_CARD2    = ( 26,  26,  46)
C_LINE     = ( 30,  30,  48)
C_WHITE    = (235, 235, 245)
C_DIM      = (110, 110, 135)
C_DIM2     = ( 74,  74,  98)
C_GREEN    = ( 68, 210, 110)
C_BLUE     = ( 90, 170, 255)
C_YELLOW   = (255, 200,  55)
C_RED      = (255,  75,  75)
C_PURPLE   = (180, 120, 255)
C_BTN      = ( 30,  30,  50)
C_BTN_PR   = ( 20,  20,  36)
# Tinted button backgrounds (matching web UI)
C_GREEN_BG = ( 18,  42,  26)
C_GREEN_PR = ( 12,  30,  18)
C_BLUE_BG  = ( 16,  32,  52)
C_BLUE_PR  = ( 10,  22,  38)
C_YELLOW_BG= ( 42,  36,  16)
C_YELLOW_PR= ( 30,  26,  10)
C_RED_BG   = ( 42,  16,  16)
C_RED_PR   = ( 30,  10,  10)
C_PURPLE_BG= ( 34,  20,  42)
C_PURPLE_PR= ( 24,  12,  30)
C_BORDER   = ( 24,  24,  40)

# ── Font loader ──────────────────────────────────────────────────────────────
_font_cache: dict = {}
_OUTFIT_REGULAR = os.path.expanduser("~/.local/share/fonts/Outfit-Regular.ttf")
_OUTFIT_BOLD    = os.path.expanduser("~/.local/share/fonts/Outfit-Bold.ttf")

def font(size: int, bold: bool = False) -> pygame.font.Font:
    key = (size, bold)
    if key not in _font_cache:
        # Try Outfit font file first
        outfit_path = _OUTFIT_BOLD if bold else _OUTFIT_REGULAR
        if os.path.exists(outfit_path):
            try:
                _font_cache[key] = pygame.font.Font(outfit_path, size)
                return _font_cache[key]
            except Exception:
                pass
        # Fallback to system fonts
        for name in ["outfit", "dejavusans", "freesans", "liberationsans", "arial", None]:
            try:
                if name:
                    f = pygame.font.SysFont(name, size, bold=bold)
                else:
                    f = pygame.font.Font(None, size)
                _font_cache[key] = f
                break
            except Exception:
                continue
    return _font_cache[key]


# ── Drawing helpers ──────────────────────────────────────────────────────────
def draw_text(surf, text, size, color, center, bold=False, max_width=None):
    f   = font(size, bold)
    img = f.render(text, True, color)
    if max_width and img.get_width() > max_width:
        while size > 10 and img.get_width() > max_width:
            size -= 2
            img = font(size, bold).render(text, True, color)
    r = img.get_rect(center=center)
    surf.blit(img, r)


# ── Button ───────────────────────────────────────────────────────────────────
class Button:
    def __init__(self, rect: pygame.Rect, label: str,
                 color=C_BTN, pressed_color=C_BTN_PR, text_color=C_WHITE,
                 sub_label: str = ""):
        self.rect          = rect
        self.label         = label
        self.sub_label     = sub_label
        self.color         = color
        self.pressed_color = pressed_color
        self.text_color    = text_color
        self.pressed       = False

    def draw(self, surf: pygame.Surface, font_size: int = 22):
        color  = self.pressed_color if self.pressed else self.color
        pygame.draw.rect(surf, color, self.rect)
        if self.sub_label:
            # Big number centered, small unit label below
            cx, cy = self.rect.center
            sub_color = tuple(c // 2 for c in self.text_color)
            f_main = font(font_size, True)
            main_img = f_main.render(self.label, True, self.text_color)
            f_sub = font(font_size // 3, False)
            sub_img = f_sub.render(self.sub_label, True, sub_color)
            gap = 2
            total_h = main_img.get_height() + sub_img.get_height() + gap
            y_start = cy - total_h // 2
            surf.blit(main_img, (cx - main_img.get_width() // 2, y_start))
            surf.blit(sub_img, (cx - sub_img.get_width() // 2,
                                y_start + main_img.get_height() + gap))
        else:
            draw_text(surf, self.label, font_size, self.text_color,
                      self.rect.center, bold=True)

    def handle_event(self, event) -> bool:
        if event.type == pygame.MOUSEBUTTONDOWN and self.rect.collidepoint(event.pos):
            self.pressed = True
        elif event.type == pygame.MOUSEBUTTONUP:
            was_pressed = self.pressed
            self.pressed = False
            if was_pressed and self.rect.collidepoint(event.pos):
                return True
        return False


def lerp_color(c1, c2, t: float):
    t = max(0.0, min(1.0, t))
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


# ── Main screen (banner + 2×2 button grid at bottom) ──────────────────────
def render_main(surf: pygame.Surface, main_btns: list,
                last_mix: str, countdown_end: float,
                last_ml: int = 0, countdown_total: float = 0) -> None:
    surf.fill(C_BG)

    # Banner area (above buttons)
    btn_h    = main_btns[0].rect.height          # actual button height
    banner_h = main_btns[0].rect.top             # top of first button row
    remaining = max(0.0, countdown_end - time.time()) if countdown_end > 0 else -1
    expired = countdown_end > 0 and remaining <= 0

    # Progress bar constants
    bar_h = 6
    bar_y = 0
    bar_margin = 0
    bar_w = W

    if expired:
        # Red-tinted banner for expired
        pygame.draw.rect(surf, (60, 8, 8), pygame.Rect(0, 0, W, banner_h))
        ml_str = f"{last_ml}ml " if last_ml else ""
        draw_text(surf, f"{ml_str}MIXED AT {last_mix}", 28, (255, 140, 140),
                  (W // 2, banner_h // 2 - 45))
        draw_text(surf, "EXPIRED", 80, C_RED,
                  (W // 2, banner_h // 2 + 30), bold=True)
        # Full red bar for expired
        pygame.draw.rect(surf, C_LINE, pygame.Rect(0, bar_y, bar_w, bar_h))
        pygame.draw.rect(surf, C_RED, pygame.Rect(0, bar_y, bar_w, bar_h))
    elif last_mix:
        ml_str = f"{last_ml}ml " if last_ml else ""
        draw_text(surf, f"{ml_str}MIXED AT", 28, C_DIM,
                  (W // 2, banner_h // 2 - 45))
        draw_text(surf, last_mix, 100, C_GREEN,
                  (W // 2, banner_h // 2 + 30), bold=True)

        # Countdown in top-right corner
        if remaining > 0:
            mins = int(remaining) // 60
            secs = int(remaining) % 60
            # Progress fraction (1.0 = full, 0.0 = empty)
            total = countdown_total if countdown_total > 0 else 3900
            frac = min(1.0, remaining / total)
            # Color: green → yellow → orange → red
            if frac > 0.5:
                t = (frac - 0.5) * 2  # 1→0 as frac goes 1→0.5
                bar_color = lerp_color(C_YELLOW, C_GREEN, t)
            elif frac > 0.15:
                t = (frac - 0.15) / 0.35  # 1→0 as frac goes 0.5→0.15
                bar_color = lerp_color((255, 140, 30), C_YELLOW, t)
            else:
                t = frac / 0.15  # 1→0 as frac goes 0.15→0
                bar_color = lerp_color(C_RED, (255, 140, 30), t)
            t_color = bar_color

            draw_text(surf, f"{mins:02d}:{secs:02d}", 44, t_color,
                      (W - 75, 30), bold=True)
            draw_text(surf, "remaining", 16, C_DIM, (W - 75, 54))

            # Progress bar
            fill_w = max(int(bar_w * frac), bar_h)
            pygame.draw.rect(surf, C_LINE, pygame.Rect(0, bar_y, bar_w, bar_h))
            pygame.draw.rect(surf, bar_color, pygame.Rect(0, bar_y, fill_w, bar_h))
    else:
        draw_text(surf, "NO BOTTLE MIXED YET", 36, C_DIM,
                  (W // 2, banner_h // 2))

    # Divider below banner
    pygame.draw.rect(surf, C_BORDER, pygame.Rect(0, banner_h - 1, W, 2))

    for btn in main_btns:
        btn.draw(surf, font_size=50 if btn.sub_label else 34)

    # Dividers between the 3×2 button grid (drawn after buttons)
    col_w      = W // 3
    row2_y     = main_btns[3].rect.top           # top of second button row
    total_btn_h = btn_h * 2
    pygame.draw.rect(surf, C_BORDER,
                     pygame.Rect(col_w - 1, banner_h, 2, total_btn_h))
    pygame.draw.rect(surf, C_BORDER,
                     pygame.Rect(col_w * 2 - 1, banner_h, 2, total_btn_h))
    pygame.draw.rect(surf, C_BORDER,
                     pygame.Rect(0, row2_y - 1, W, 2))

    # WiFi indicator — top-left, just below progress bar
    draw_wifi(surf, 30, 22, _wifi_connected())

    pygame.display.flip()


# ── Samples screen (4 combo cards) ────────────────────────────────────────
def render_samples(surf: pygame.Surface, back_btn: Button) -> None:
    surf.fill(C_BG)

    card_area_y = 0
    card_area_h = H - 100
    card_w = W // 4
    card_h = card_area_h

    for i, (water_ml, powder_g) in enumerate(COMBOS):
        x = i * card_w
        y = card_area_y
        rect = pygame.Rect(x, y, card_w, card_h)

        card_bg = C_CARD2 if i % 2 == 1 else C_CARD
        pygame.draw.rect(surf, card_bg, rect)
        if i > 0:
            pygame.draw.line(surf, C_LINE, (x, y), (x, y + card_h))

        cx = x + card_w // 2

        draw_text(surf, "WATER", 14, C_DIM, (cx, y + 22))
        draw_text(surf, f"{water_ml}", 80, C_BLUE, (cx, y + 85), bold=True)
        draw_text(surf, "ml", 22, C_DIM, (cx, y + 130))

        pygame.draw.line(surf, C_LINE,
                         (x + 16, y + card_h // 2),
                         (x + card_w - 16, y + card_h // 2))

        draw_text(surf, "POWDER", 14, C_DIM, (cx, y + card_h // 2 + 22))
        draw_text(surf, f"{powder_g:.1f}", 80, C_GREEN,
                  (cx, y + card_h // 2 + 85), bold=True)
        draw_text(surf, "g", 22, C_DIM, (cx, y + card_h // 2 + 130))

    pygame.draw.rect(surf, C_BORDER, pygame.Rect(0, H - 102, W, 2))
    back_btn.draw(surf, font_size=24)

    pygame.display.flip()


# ── Log screen ─────────────────────────────────────────────────────────────
LOG_CARD_H = 62
LOG_CARD_PAD = 5
LOG_CARD_Y0 = 82
LOG_MAX_SHOW = 5


def _entry_date(entry) -> str:
    """Extract YYYY-MM-DD from a log entry, or '' if unavailable."""
    if isinstance(entry, dict) and entry.get("date"):
        return entry["date"].split(" ")[0]
    return ""


def _log_dates(mix_log: list) -> list:
    """Return sorted unique date strings from the log."""
    dates = set()
    for e in mix_log:
        d = _entry_date(e)
        if d:
            dates.add(d)
    return sorted(dates)


def _filter_log_by_date(mix_log: list, date_str: str) -> list:
    """Return list of (real_index, entry) for entries matching date_str.
    If date_str is empty, return entries with no date."""
    result = []
    for i, e in enumerate(mix_log):
        d = _entry_date(e)
        if date_str and d == date_str:
            result.append((i, e))
        elif not date_str and not d:
            result.append((i, e))
    return result


def _log_card_rects(filtered: list, scroll: int = 0) -> list:
    """Return list of (card_rect, real_index) for displayed entries (newest first)."""
    rects = []
    all_shown = list(reversed(filtered))
    start = max(0, min(scroll, max(0, len(all_shown) - LOG_MAX_SHOW)))
    shown = all_shown[start:start + LOG_MAX_SHOW]
    y = LOG_CARD_Y0
    for real_idx, _entry in shown:
        rects.append((pygame.Rect(10, y, W - 20, LOG_CARD_H), real_idx))
        y += LOG_CARD_H + LOG_CARD_PAD
    return rects


def _format_date_label(date_str: str) -> str:
    """Format YYYY-MM-DD to a nice label."""
    if not date_str:
        return "Undated"
    try:
        d = datetime.strptime(date_str, "%Y-%m-%d")
        today = datetime.now().strftime("%Y-%m-%d")
        if date_str == today:
            return "Today"
        # Check yesterday
        from datetime import timedelta
        yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        if date_str == yesterday:
            return "Yesterday"
        return d.strftime("%b %d, %Y")
    except Exception:
        return date_str


def render_log(surf: pygame.Surface, mix_log: list,
               back_btn: Button, selected_idx: int,
               log_leftover_btn: Button, log_delete_btn: Button,
               log_prev_btn: Button, log_next_btn: Button,
               log_view_date: str, trends_btn: Button = None,
               log_scroll: int = 0) -> None:
    surf.fill(C_BG)

    # Date header with prev/next arrows
    date_label = _format_date_label(log_view_date)
    dates = _log_dates(mix_log)
    has_prev = log_view_date and dates and dates.index(log_view_date) > 0 if log_view_date in dates else False
    has_next = log_view_date and dates and dates.index(log_view_date) < len(dates) - 1 if log_view_date in dates else False

    # Undated entries exist?
    undated = [e for e in mix_log if not _entry_date(e)]
    if undated and log_view_date and dates and dates[0] == log_view_date:
        has_prev = True  # can go to "undated"
    if not log_view_date and dates:
        has_next = True  # from undated can go to first dated

    draw_text(surf, date_label, 30, C_WHITE, (W // 2, 30), bold=True)

    # Prev/Next arrows in header
    if has_prev:
        log_prev_btn.draw(surf, font_size=26)
    if has_next:
        log_next_btn.draw(surf, font_size=26)


    # Filter entries for current date
    filtered = _filter_log_by_date(mix_log, log_view_date)

    if not filtered:
        draw_text(surf, "No entries for this day", 26, C_DIM, (W // 2, (H - 100) // 2))
    else:
        count_label = f"{len(filtered)} bottle{'s' if len(filtered) != 1 else ''}"
        draw_text(surf, count_label, 18, C_DIM, (W // 2, 54))

        # Scroll indicator
        if len(filtered) > LOG_MAX_SHOW:
            draw_text(surf, f"↑↓ swipe  ({log_scroll+1}–{min(log_scroll+LOG_MAX_SHOW,len(filtered))}/{len(filtered)})",
                      13, C_DIM, (W // 2, 72))

        for card_rect, real_idx in _log_card_rects(filtered, log_scroll):
            entry = mix_log[real_idx]
            txt = entry["text"] if isinstance(entry, dict) else entry
            leftover = entry.get("leftover", "") if isinstance(entry, dict) else ""
            disp_idx = real_idx  # use real index for numbering

            # Card background
            card_bg = C_CARD2 if (real_idx % 2 == 0) else C_CARD
            pygame.draw.rect(surf, card_bg, card_rect, border_radius=8)
            if real_idx == selected_idx:
                pygame.draw.rect(surf, C_BLUE, card_rect, width=2, border_radius=8)

            # Entry number
            draw_text(surf, str(disp_idx + 1), 18, C_DIM, (30, card_rect.centery))

            # Time only (strip date from text if present)
            draw_text(surf, txt, 26, C_WHITE,
                      (W // 2, card_rect.centery - (8 if leftover else 0)), bold=True)

            # Leftover
            if leftover:
                draw_text(surf, f"leftover: {leftover}", 16, C_YELLOW,
                          (W // 2, card_rect.centery + 15))

    # Bottom bar
    pygame.draw.rect(surf, C_BORDER, pygame.Rect(0, H - 102, W, 2))
    if selected_idx >= 0:
        back_btn.draw(surf, font_size=28)
        log_leftover_btn.draw(surf, font_size=24)
        log_delete_btn.draw(surf, font_size=24)
        btn_w = W // 3
        pygame.draw.rect(surf, C_BORDER, pygame.Rect(btn_w - 1, H - 100, 2, 100))
        pygame.draw.rect(surf, C_BORDER, pygame.Rect(btn_w * 2 - 1, H - 100, 2, 100))
    else:
        back_btn.draw(surf, font_size=28)
        if trends_btn:
            trends_btn.draw(surf, font_size=28)
            pygame.draw.rect(surf, C_BORDER, pygame.Rect(W // 2 - 1, H - 100, 2, 100))

    pygame.display.flip()


# ── Numpad overlay for leftover entry ──────────────────────────────────────
NUMPAD_KEYS = [
    ["1", "2", "3"],
    ["4", "5", "6"],
    ["7", "8", "9"],
    ["C", "0", "OK"],
]


def _numpad_rects() -> list:
    """Return list of (rect, label) for numpad buttons."""
    pad_w, pad_h = 300, 280
    px = (W - pad_w) // 2
    py = (H - pad_h) // 2 + 30
    btn_w = pad_w // 3
    btn_h = pad_h // 4
    result = []
    for row_i, row in enumerate(NUMPAD_KEYS):
        for col_i, label in enumerate(row):
            rect = pygame.Rect(px + col_i * btn_w, py + row_i * btn_h, btn_w, btn_h)
            result.append((rect, label))
    return result


def render_numpad(surf: pygame.Surface, title: str, value: str) -> None:
    """Draw a numpad overlay on top of the current screen."""
    # Dim overlay
    overlay = pygame.Surface((W, H), pygame.SRCALPHA)
    overlay.fill((0, 0, 0, 180))
    surf.blit(overlay, (0, 0))

    # Dialog background
    dlg_w, dlg_h = 340, 370
    dlg_x = (W - dlg_w) // 2
    dlg_y = (H - dlg_h) // 2
    pygame.draw.rect(surf, C_CARD, pygame.Rect(dlg_x, dlg_y, dlg_w, dlg_h),
                     border_radius=14)

    # Title
    draw_text(surf, title, 20, C_WHITE, (W // 2, dlg_y + 20), bold=True)

    # Value display
    val_rect = pygame.Rect(dlg_x + 20, dlg_y + 40, dlg_w - 40, 36)
    pygame.draw.rect(surf, C_BG, val_rect, border_radius=8)
    pygame.draw.rect(surf, C_LINE, val_rect, width=1, border_radius=8)
    display_val = value if value else ""
    draw_text(surf, display_val + " ml", 22, C_WHITE, val_rect.center)

    # Numpad buttons
    for rect, label in _numpad_rects():
        if label == "OK":
            bg = C_GREEN_BG
            tc = C_GREEN
        elif label == "C":
            bg = C_RED_BG
            tc = C_RED
        else:
            bg = C_BTN
            tc = C_WHITE
        pygame.draw.rect(surf, bg, rect.inflate(-4, -4), border_radius=8)
        draw_text(surf, label, 24, tc, rect.center, bold=True)

    pygame.display.flip()




# ── Trends screen ─────────────────────────────────────────────────────────
_wifi_cache: tuple = (False, 0.0)  # (connected, timestamp)

def _wifi_connected() -> bool:
    """Check WiFi by probing a UDP route; cached for 5s to avoid per-frame overhead."""
    global _wifi_cache
    connected, ts = _wifi_cache
    if time.monotonic() - ts < 5.0:
        return connected
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1)
        s.connect(("8.8.8.8", 80))
        s.close()
        connected = True
    except Exception:
        connected = False
    _wifi_cache = (connected, time.monotonic())
    return connected


def draw_wifi(surf: pygame.Surface, cx: int, cy: int, connected: bool) -> None:
    """Draw a small WiFi icon (3 arcs + dot) at 50% opacity."""
    import math
    base = C_GREEN if connected else C_RED
    color = (base[0], base[1], base[2], 128)
    tmp = pygame.Surface((60, 40), pygame.SRCALPHA)
    tx, ty = 30, 10
    dot_r = 3
    pygame.draw.circle(tmp, color, (tx, ty + 20), dot_r)
    for r, w in [(10, 2), (17, 2), (24, 2)]:
        rect = pygame.Rect(tx - r, ty + 20 - r, r * 2, r * 2)
        pygame.draw.arc(tmp, color, rect, math.radians(30), math.radians(150), w)
    surf.blit(tmp, (cx - 30, cy - 10))


TREND_RANGES = ["Week", "Month", "Year", "All"]
TREND_DAYS = {"Week": 7, "Month": 30, "Year": 365, "All": 99999}


def _aggregate_trends(mix_log: list, range_name: str) -> tuple:
    """Return (daily_dict, daily_leftover_dict, total_ml, count) for the given range."""
    from datetime import timedelta
    cutoff_days = TREND_DAYS[range_name]
    cutoff_date = (datetime.now() - timedelta(days=cutoff_days)).strftime("%Y-%m-%d")

    daily = {}
    daily_leftover = {}
    total_ml = 0
    count = 0
    for e in mix_log:
        if isinstance(e, str):
            continue
        ml = e.get("ml", 0)
        date_str = (e.get("date", "") or "").split(" ")[0]
        if not date_str or not ml:
            continue
        if date_str < cutoff_date:
            continue
        daily[date_str] = daily.get(date_str, 0) + ml
        total_ml += ml
        count += 1
        # Parse leftover e.g. "20ml" → 20
        lo_str = e.get("leftover", "") or ""
        try:
            lo_ml = int(''.join(filter(str.isdigit, lo_str))) if lo_str else 0
        except Exception:
            lo_ml = 0
        if lo_ml:
            daily_leftover[date_str] = daily_leftover.get(date_str, 0) + lo_ml

    return daily, daily_leftover, total_ml, count


def render_trends(surf: pygame.Surface, mix_log: list,
                  range_btns: list, trend_range_idx: int,
                  back_btn: Button) -> None:
    surf.fill(C_BG)

    draw_text(surf, "CONSUMPTION TRENDS", 22, C_WHITE, (W // 2, 24), bold=True)

    # Tab buttons
    for i, btn in enumerate(range_btns):
        if i == trend_range_idx:
            btn.color = C_BLUE_BG
            btn.text_color = C_BLUE
        else:
            btn.color = C_BTN
            btn.text_color = C_DIM
        btn.draw(surf, font_size=16)

    range_name = TREND_RANGES[trend_range_idx]
    daily, daily_leftover, total_ml, count = _aggregate_trends(mix_log, range_name)

    # Summary stats
    stat_y = 80
    stat_w = W // 3
    num_days = max(1, len(daily))
    avg_per_day = round(total_ml / num_days) if num_days else 0

    stats = [
        (str(total_ml), "TOTAL ML"),
        (str(count), "BOTTLES"),
        (str(avg_per_day), "AVG ML/DAY"),
    ]
    for i, (val, lbl) in enumerate(stats):
        cx = stat_w * i + stat_w // 2
        pygame.draw.rect(surf, C_CARD,
                         pygame.Rect(stat_w * i + 6, stat_y, stat_w - 12, 56),
                         border_radius=10)
        draw_text(surf, val, 24, C_BLUE, (cx, stat_y + 18), bold=True)
        draw_text(surf, lbl, 11, C_DIM, (cx, stat_y + 42))

    # Bar chart area
    chart_top = 150
    chart_bottom = H - 110
    chart_h = chart_bottom - chart_top
    chart_left = 60
    chart_right = W - 20

    if not daily:
        draw_text(surf, "No data for this period", 20, C_DIM,
                  (W // 2, chart_top + chart_h // 2))
    else:
        days_sorted = sorted(daily.keys())
        # Fill missing dates
        from datetime import timedelta
        all_days = []
        if len(days_sorted) >= 2:
            cur = datetime.strptime(days_sorted[0], "%Y-%m-%d")
            end = datetime.strptime(days_sorted[-1], "%Y-%m-%d")
            while cur <= end:
                all_days.append(cur.strftime("%Y-%m-%d"))
                cur += timedelta(days=1)
        else:
            all_days = days_sorted

        max_val = max(daily.values()) if daily else 1
        bar_count = len(all_days)
        avail_w = chart_right - chart_left
        bar_w = max(4, min(40, (avail_w - bar_count) // max(1, bar_count)))
        gap = max(1, (avail_w - bar_w * bar_count) // max(1, bar_count + 1))

        # Y-axis labels
        for frac in [0, 0.5, 1.0]:
            y = chart_bottom - int(chart_h * frac)
            val = int(max_val * frac)
            draw_text(surf, str(val), 11, C_DIM, (chart_left - 8, y))
            pygame.draw.line(surf, C_LINE, (chart_left, y), (chart_right, y), 1)

        # Bars
        for i, day in enumerate(all_days):
            val = daily.get(day, 0)
            bar_h = int((val / max(1, max_val)) * (chart_h - 10))
            x = chart_left + gap + i * (bar_w + gap)
            y = chart_bottom - bar_h
            bar_color = C_BLUE if val > 0 else C_LINE
            pygame.draw.rect(surf, bar_color,
                             pygame.Rect(x, y, bar_w, bar_h),
                             border_radius=min(3, bar_w // 2))
            # Leftover overlay in yellow at the top of the bar
            lo_val = daily_leftover.get(day, 0)
            if lo_val and bar_h > 0:
                lo_h = max(2, int((lo_val / max(1, max_val)) * (chart_h - 10)))
                lo_h = min(lo_h, bar_h)
                pygame.draw.rect(surf, C_YELLOW,
                                 pygame.Rect(x, y, bar_w, lo_h),
                                 border_radius=min(3, bar_w // 2))

            # Date label (show for first, last, and every ~5th)
            if bar_count <= 10 or i == 0 or i == bar_count - 1 or i % max(1, bar_count // 5) == 0:
                try:
                    d = datetime.strptime(day, "%Y-%m-%d")
                    lbl = d.strftime("%b %d")
                except Exception:
                    lbl = day
                draw_text(surf, lbl, 10, C_DIM, (x + bar_w // 2, chart_bottom + 10))

    # Bottom bar
    pygame.draw.rect(surf, C_BORDER, pygame.Rect(0, H - 102, W, 2))
    back_btn.draw(surf, font_size=24)

    pygame.display.flip()


# ── Calculator screen ────────────────────────────────────────────────────────
def render_calculator(surf: pygame.Surface, water_ml: int,
                      plus_btn: Button, minus_btn: Button,
                      back_btn: Button, timer_btn: Button) -> None:
    surf.fill(C_BG)

    powder_g = water_ml * (POWDER_PER_60ML / 60.0)

    # ── Left half: Water ─────────────────────────────────────────────────────
    left_w = W // 2
    btn_w  = plus_btn.rect.width
    water_cx = (left_w - btn_w) // 2  # center between left edge and +/- buttons
    pygame.draw.rect(surf, C_CARD, pygame.Rect(0, 0, left_w, H - 100))

    draw_text(surf, "WATER", 16, C_DIM, (water_cx, 30))

    mid_y = (H - 100) // 2
    draw_text(surf, f"{water_ml}", 140, C_BLUE, (water_cx, mid_y - 20),
              bold=True)
    draw_text(surf, "ml", 30, C_DIM, (water_cx, mid_y + 55))

    # +/- buttons
    plus_btn.draw(surf, font_size=36)
    minus_btn.draw(surf, font_size=36)

    # ── Right half: Powder ───────────────────────────────────────────────────
    right_x = W // 2
    bg = C_GREEN_BG if water_ml > 0 else C_CARD
    pygame.draw.rect(surf, bg, pygame.Rect(right_x, 0, left_w, H - 100))
    # Divider
    pygame.draw.line(surf, C_LINE, (right_x, 0), (right_x, H - 100))

    lbl_color = C_GREEN if water_ml > 0 else C_DIM
    draw_text(surf, "POWDER", 16, lbl_color, (right_x + left_w // 2, 30))

    p_txt = f"{powder_g:.1f}" if water_ml > 0 else "--"
    p_color = C_GREEN if water_ml > 0 else C_DIM
    draw_text(surf, p_txt, 140, p_color, (right_x + left_w // 2, mid_y - 20),
              bold=True)
    draw_text(surf, "g", 30, p_color, (right_x + left_w // 2, mid_y + 55))

    # Divider between content and buttons
    pygame.draw.rect(surf, C_BORDER, pygame.Rect(0, H - 102, W, 2))

    # Bottom buttons
    back_btn.draw(surf, font_size=24)
    timer_btn.draw(surf, font_size=24)

    pygame.display.flip()



# ── Screensaver ─────────────────────────────────────────────────────────────
BOTTLE_IMG_PATH = os.path.join(_APP_DIR, "bottle_vector.png")
BABY_IMG_PATH   = os.path.join(_APP_DIR, "baby.png")
SS_SIZE = 120  # height in pixels for screensaver sprites

_ss_images = {}


def _flood_remove_bg(img: pygame.Surface, threshold: int = 220) -> None:
    """Flood-fill from edges to remove white background only (not interior)."""
    w, h = img.get_size()
    visited = set()
    queue = []
    # Seed from all edge pixels
    for x in range(w):
        queue.append((x, 0))
        queue.append((x, h - 1))
    for y in range(h):
        queue.append((0, y))
        queue.append((w - 1, y))

    img.lock()
    while queue:
        x, y = queue.pop()
        if (x, y) in visited or x < 0 or x >= w or y < 0 or y >= h:
            continue
        visited.add((x, y))
        r, g, b, a = img.get_at((x, y))
        if r > threshold and g > threshold and b > threshold and a > 0:
            img.set_at((x, y), (r, g, b, 0))
            queue.append((x + 1, y))
            queue.append((x - 1, y))
            queue.append((x, y + 1))
            queue.append((x, y - 1))
    img.unlock()


def _load_ss_img(path: str, remove_white: bool = False,
                 lighten_dark: bool = False) -> pygame.Surface:
    """Load, clean up background, crop, and scale a screensaver sprite."""
    if path in _ss_images:
        return _ss_images[path]
    img = pygame.image.load(path).convert_alpha()
    if remove_white:
        _flood_remove_bg(img)
    if lighten_dark:
        img.lock()
        for x in range(img.get_width()):
            for y in range(img.get_height()):
                r, g, b, a = img.get_at((x, y))
                if a > 0 and r < 60 and g < 60 and b < 60:
                    img.set_at((x, y), (180, 180, 180, a))
        img.unlock()
    # Crop transparent edges
    mask = pygame.mask.from_surface(img)
    rects = mask.get_bounding_rects()
    if rects:
        crop = rects[0]
        for r in rects[1:]:
            crop.union_ip(r)
        img = img.subsurface(crop).copy()
    # Scale proportionally to target height
    scale = SS_SIZE / img.get_height()
    new_w = int(img.get_width() * scale)
    img = pygame.transform.smoothscale(img, (new_w, SS_SIZE))
    _ss_images[path] = img
    return img


def get_bottle_img() -> pygame.Surface:
    return _load_ss_img(BOTTLE_IMG_PATH, remove_white=True, lighten_dark=True)


def get_baby_img() -> pygame.Surface:
    return _load_ss_img(BABY_IMG_PATH, remove_white=True, lighten_dark=False)


_ss_clock_pos = None
_ss_clock_last_move = 0.0

def render_screensaver(surf: pygame.Surface, sprites: list) -> None:
    """sprites: list of (x, y, flip_h, flip_v, img_getter)"""
    global _ss_clock_pos, _ss_clock_last_move
    import random
    surf.fill((0, 0, 0))
    for sx, sy, fh, fv, getter in sprites:
        img = getter()
        img = pygame.transform.flip(img, fh, fv)
        rect = img.get_rect(center=(int(sx), int(sy)))
        surf.blit(img, rect)

    # Faint digital clock that moves every 5 minutes
    now = time.time()
    if _ss_clock_pos is None or now - _ss_clock_last_move > 300:
        _ss_clock_pos = (random.randint(100, W - 100), random.randint(60, H - 60))
        _ss_clock_last_move = now
    clock_str = datetime.now().strftime("%I:%M %p")
    draw_text(surf, clock_str, 36, (40, 40, 55), _ss_clock_pos, bold=True)

    pygame.display.flip()


# ── Main ─────────────────────────────────────────────────────────────────────
def main(fullscreen: bool, simulate: bool) -> None:
    pygame.init()
    pygame.mouse.set_visible(False)

    flags = pygame.FULLSCREEN if fullscreen else 0
    if simulate and not fullscreen:
        win  = pygame.display.set_mode((W, H))
        surf = pygame.Surface((W, H))
        pygame.display.set_caption("Formula Helper  [SIMULATE]")
    else:
        surf = pygame.display.set_mode((W, H), flags)
        win  = surf
        pygame.display.set_caption("Formula Helper")

    clock = pygame.time.Clock()

    # ── Main screen buttons (3×2 grid, 120px tall each, pinned to bottom) ──
    main_btn_h = 120
    col_w = W // 3
    row1_y = H - main_btn_h * 2
    row2_y = H - main_btn_h
    main_start60_btn = Button(
        pygame.Rect(0, row1_y, col_w, main_btn_h),
        "60", sub_label="ml",
        color=C_GREEN_BG, pressed_color=C_GREEN_PR, text_color=C_GREEN,
    )
    main_start90_btn = Button(
        pygame.Rect(col_w, row1_y, col_w, main_btn_h),
        "90", sub_label="ml",
        color=C_GREEN_BG, pressed_color=C_GREEN_PR, text_color=C_GREEN,
    )
    main_start120_btn = Button(
        pygame.Rect(col_w * 2, row1_y, W - col_w * 2, main_btn_h),
        "120", sub_label="ml",
        color=C_GREEN_BG, pressed_color=C_GREEN_PR, text_color=C_GREEN,
    )
    main_log_btn = Button(
        pygame.Rect(0, row2_y, col_w, main_btn_h),
        "Log",
        color=C_YELLOW_BG, pressed_color=C_YELLOW_PR, text_color=C_YELLOW,
    )
    main_samples_btn = Button(
        pygame.Rect(col_w, row2_y, col_w, main_btn_h),
        "Sample Sizes",
        color=C_BLUE_BG, pressed_color=C_BLUE_PR, text_color=C_BLUE,
    )
    main_custom_btn = Button(
        pygame.Rect(col_w * 2, row2_y, W - col_w * 2, main_btn_h),
        "Custom Amount",
        color=C_PURPLE_BG, pressed_color=C_PURPLE_PR, text_color=C_PURPLE,
    )
    main_btns = [main_start60_btn, main_start90_btn, main_start120_btn,
                 main_log_btn, main_samples_btn, main_custom_btn]

    # ── Samples screen buttons ───────────────────────────────────────────────
    samples_back_btn = Button(pygame.Rect(0, H - 100, W, 100), "Back")

    # ── Log screen buttons ───────────────────────────────────────────────────
    log_btn_w = W // 3
    log_back_btn = Button(pygame.Rect(0, H - 100, W // 2, 100), "Back")
    log_trends_btn = Button(
        pygame.Rect(W // 2, H - 100, W // 2, 100),
        "Trends", color=C_BLUE_BG, pressed_color=C_BLUE_PR, text_color=C_BLUE,
    )
    log_leftover_btn = Button(
        pygame.Rect(log_btn_w, H - 100, log_btn_w, 100),
        "Leftover", color=C_YELLOW_BG, pressed_color=C_YELLOW_PR, text_color=C_YELLOW,
    )
    log_delete_btn = Button(
        pygame.Rect(log_btn_w * 2, H - 100, W - log_btn_w * 2, 100),
        "Delete", color=C_RED_BG, pressed_color=C_RED_PR, text_color=C_RED,
    )
    log_prev_btn = Button(
        pygame.Rect(10, 10, 60, 36),
        "<", color=(38, 38, 58), pressed_color=(25, 25, 40), text_color=C_DIM,
    )
    log_next_btn = Button(
        pygame.Rect(W - 70, 10, 60, 36),
        ">", color=(38, 38, 58), pressed_color=(25, 25, 40), text_color=C_DIM,
    )

    # ── Calculator screen buttons ────────────────────────────────────────────
    calc_btn_w = 110
    calc_plus_btn = Button(
        pygame.Rect(W // 2 - calc_btn_w, 0, calc_btn_w, (H - 100) // 2),
        "+", color=C_BLUE_BG, pressed_color=C_BLUE_PR, text_color=C_BLUE,
    )
    calc_minus_btn = Button(
        pygame.Rect(W // 2 - calc_btn_w, (H - 100) // 2, calc_btn_w, (H - 100) // 2),
        "-", color=C_RED_BG, pressed_color=C_RED_PR, text_color=C_RED,
    )
    calc_back_btn = Button(
        pygame.Rect(0, H - 100, W // 2, 100),
        "Back",
    )
    calc_timer_btn = Button(
        pygame.Rect(W // 2, H - 100, W // 2, 100),
        "Start Timer",
        color=C_GREEN_BG, pressed_color=C_GREEN_PR, text_color=C_GREEN,
    )

    # ── Trends screen buttons ────────────────────────────────────────────────
    trend_tab_w = 80
    trend_tab_h = 30
    trend_tab_y = 46
    trend_tab_x0 = (W - trend_tab_w * 4 - 24) // 2
    trend_range_btns = []
    for i, name in enumerate(TREND_RANGES):
        trend_range_btns.append(Button(
            pygame.Rect(trend_tab_x0 + i * (trend_tab_w + 8), trend_tab_y,
                        trend_tab_w, trend_tab_h),
            name, color=C_BTN, text_color=C_DIM,
        ))
    trends_back_btn = Button(pygame.Rect(0, H - 100, W, 100), "Back")
    trend_range_idx = 0

    # ── State (from cloud API) ──────────────────────────────────────────────────
    api_client.init()
    cloud          = api_client.get_state()
    settings       = cloud.get("settings", {"countdown_secs": 3900, "ss_timeout_min": 2})
    countdown_secs = settings.get("countdown_secs", DEFAULT_COUNTDOWN_MIN * 60)
    ss_timeout_min = settings.get("ss_timeout_min", 2)

    mode           = AppMode.MAIN
    countdown_end  = cloud.get("countdown_end", 0.0)
    ntfy_sent      = cloud.get("ntfy_sent", False)
    mixed_at_str   = cloud.get("mixed_at_str", "")
    mixed_ml       = cloud.get("mixed_ml", 0)
    calc_water_ml  = 60  # calculator water amount
    mix_log        = cloud.get("mix_log", [])
    log_selected   = -1   # index of selected log entry (-1 = none)
    log_view_date  = ""   # YYYY-MM-DD or "" for today
    log_scroll     = 0    # scroll offset into reversed entry list
    log_drag_start = None # (x, y) of finger-down for swipe detection
    numpad_active  = False
    numpad_value   = ""
    dot_frame      = 0
    running        = True
    last_frame_key = None
    last_input     = time.monotonic()
    last_sync      = 0.0  # last time we synced state from API
    pre_ss_mode    = AppMode.MAIN  # mode to return to after screensaver

    # Background state poller — keeps main loop free of network I/O
    class _BgCloud:
        def __init__(self):
            self._lock = threading.Lock()
            self._data = None
        def put(self, d):
            with self._lock: self._data = d
        def get(self):
            with self._lock:
                d = self._data; self._data = None; return d

    _bg_cloud = _BgCloud()

    def _poll_loop():
        while True:
            time.sleep(5)
            try:
                _bg_cloud.put(api_client.poll_state())
            except Exception:
                pass

    threading.Thread(target=_poll_loop, daemon=True).start()

    # Screensaver bouncing sprites: [x, y, dx, dy, flip_h, flip_v, img_getter]
    ss_sprites = [
        [200.0, 150.0, 2.5, 1.8, False, False, get_bottle_img],
        [500.0, 300.0, -2.0, 2.2, False, False, get_baby_img],
    ]

    # Flush stale touch events that accumulated before the app started
    pygame.time.wait(200)
    pygame.event.clear()

    _ss_just_dismissed = False   # suppress UP that follows screensaver-dismiss DOWN
    _dbg_pos = None              # last touch position for overlay
    _last_down = (0, 0, 0)       # (x, y, ticks) — for duplicate-event suppression

    while running:
        dot_frame += 1
        btn_changed = False

        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            if event.type == pygame.KEYDOWN and event.key == pygame.K_q:
                running = False

            # Track user input for screensaver timeout
            # Drop duplicate touch+pointer events labwc fires for the same tap
            if event.type == pygame.MOUSEBUTTONDOWN:
                x, y = event.pos
                lx, ly, lt = _last_down
                now_ms = pygame.time.get_ticks()
                if abs(x - lx) < 8 and abs(y - ly) < 8 and now_ms - lt < 50:
                    with open("/tmp/touch_debug.log", "a") as _f:
                        _f.write(f"DUP-DROPPED {event.pos} delta={now_ms - lt}ms\n")
                    continue
                _last_down = (x, y, now_ms)

            if event.type in (pygame.MOUSEBUTTONDOWN, pygame.MOUSEBUTTONUP,
                              pygame.KEYDOWN):
                if event.type in (pygame.MOUSEBUTTONDOWN, pygame.MOUSEBUTTONUP):
                    _dbg_pos = event.pos
                    _dbg_type = "DN" if event.type == pygame.MOUSEBUTTONDOWN else "UP"
                    with open("/tmp/touch_debug.log", "a") as _f:
                        _f.write(f"{_dbg_type} {event.pos} mode={mode.name} t={pygame.time.get_ticks()}\n")
                last_input = time.monotonic()
                if mode == AppMode.SCREENSAVER:
                    if event.type == pygame.MOUSEBUTTONDOWN:
                        mode = pre_ss_mode
                        last_frame_key = None
                        btn_changed = True
                        _ss_just_dismissed = True
                    continue

            # Suppress the UP that corresponds to the screensaver-dismissing DOWN
            if event.type == pygame.MOUSEBUTTONUP and _ss_just_dismissed:
                _ss_just_dismissed = False
                continue

            if mode == AppMode.SCREENSAVER:
                continue

            if mode == AppMode.MAIN:
                if main_start60_btn.handle_event(event):
                    countdown_end = time.time() + countdown_secs
                    mixed_at_str  = datetime.now().strftime("%I:%M %p")
                    mixed_ml      = 60
                    api_client.start_timer_async(60)
                    ntfy_sent     = False
                    btn_changed   = True
                elif main_start90_btn.handle_event(event):
                    countdown_end = time.time() + countdown_secs
                    mixed_at_str  = datetime.now().strftime("%I:%M %p")
                    mixed_ml      = 90
                    api_client.start_timer_async(90)
                    ntfy_sent     = False
                    btn_changed   = True
                elif main_start120_btn.handle_event(event):
                    countdown_end = time.time() + countdown_secs
                    mixed_at_str  = datetime.now().strftime("%I:%M %p")
                    mixed_ml      = 120
                    api_client.start_timer_async(120)
                    ntfy_sent     = False
                    btn_changed   = True
                elif main_log_btn.handle_event(event):
                    mode        = AppMode.LOG
                    mix_log     = api_client.get_log()
                    log_selected = -1
                    numpad_active = False
                    log_view_date = datetime.now().strftime("%Y-%m-%d")
                    log_back_btn.rect = pygame.Rect(0, H - 100, W // 2, 100)
                    btn_changed = True
                elif main_samples_btn.handle_event(event):
                    mode        = AppMode.SAMPLES
                    btn_changed = True
                elif main_custom_btn.handle_event(event):
                    mode        = AppMode.CALCULATOR
                    btn_changed = True

            elif mode == AppMode.SAMPLES:
                if samples_back_btn.handle_event(event):
                    mode        = AppMode.MAIN
                    btn_changed = True

            elif mode == AppMode.LOG:
                # Always track drag start for swipe detection
                if event.type == pygame.MOUSEBUTTONDOWN:
                    log_drag_start = event.pos
                if numpad_active:
                    # Handle numpad taps
                    if event.type == pygame.MOUSEBUTTONUP:
                        for rect, label in _numpad_rects():
                            if rect.collidepoint(event.pos):
                                if label == "OK":
                                    if log_selected >= 0 and log_selected < len(mix_log):
                                        entry = mix_log[log_selected]
                                        if isinstance(entry, str):
                                            entry = {"text": entry, "leftover": ""}
                                            mix_log[log_selected] = entry
                                        entry["leftover"] = (numpad_value + "ml") if numpad_value else ""
                                        sk = entry.get("sk", "") if isinstance(entry, dict) else ""
                                        if sk:
                                            api_client.edit_log_entry(sk, {"leftover": entry["leftover"]})
                                    numpad_active = False
                                    numpad_value = ""
                                    btn_changed = True
                                elif label == "C":
                                    numpad_value = ""
                                    btn_changed = True
                                else:
                                    if len(numpad_value) < 4:
                                        numpad_value += label
                                    btn_changed = True
                                break
                elif log_back_btn.handle_event(event):
                    if log_selected >= 0:
                        log_selected = -1
                        log_back_btn.rect = pygame.Rect(0, H - 100, W // 2, 100)
                    else:
                        mode = AppMode.MAIN
                    btn_changed = True
                elif log_trends_btn.handle_event(event) and log_selected < 0:
                    mode = AppMode.TRENDS
                    mix_log = api_client.get_log()
                    btn_changed = True
                elif log_prev_btn.handle_event(event):
                    dates = _log_dates(mix_log)
                    undated = [e for e in mix_log if not _entry_date(e)]
                    if log_view_date in dates:
                        idx = dates.index(log_view_date)
                        if idx > 0:
                            log_view_date = dates[idx - 1]
                        elif undated:
                            log_view_date = ""  # go to undated
                    log_selected = -1
                    log_scroll = 0
                    log_back_btn.rect = pygame.Rect(0, H - 100, W // 2, 100)
                    btn_changed = True
                elif log_next_btn.handle_event(event):
                    dates = _log_dates(mix_log)
                    if not log_view_date and dates:
                        log_view_date = dates[0]
                    elif log_view_date in dates:
                        idx = dates.index(log_view_date)
                        if idx < len(dates) - 1:
                            log_view_date = dates[idx + 1]
                    log_selected = -1
                    log_scroll = 0
                    log_back_btn.rect = pygame.Rect(0, H - 100, W // 2, 100)
                    btn_changed = True
                elif log_selected >= 0 and log_leftover_btn.handle_event(event):
                    numpad_active = True
                    existing = ""
                    if log_selected < len(mix_log):
                        e = mix_log[log_selected]
                        if isinstance(e, dict):
                            existing = e.get("leftover", "").replace("ml", "")
                    numpad_value = existing
                    btn_changed = True
                elif log_selected >= 0 and log_delete_btn.handle_event(event):
                    if log_selected < len(mix_log):
                        entry = mix_log[log_selected]
                        sk = entry.get("sk", "") if isinstance(entry, dict) else ""
                        if sk:
                            api_client.delete_log_entry_async(sk)
                        # Check if this entry is driving the current timer
                        entry_time = ""
                        try:
                            from datetime import datetime as _dt
                            entry_time = _dt.strptime(
                                entry.get("date", ""), "%Y-%m-%d %I:%M %p"
                            ).strftime("%I:%M %p")
                        except (ValueError, AttributeError, KeyError):
                            pass
                        mix_log.pop(log_selected)
                        if entry_time and entry_time == mixed_at_str:
                            # Restore timer from new latest remaining entry
                            remaining = sorted(mix_log, key=lambda e: e.get("sk", ""))
                            if remaining:
                                try:
                                    latest = remaining[-1]
                                    latest_dt = _dt.strptime(
                                        latest.get("date", ""), "%Y-%m-%d %I:%M %p"
                                    )
                                    mixed_at_str = latest_dt.strftime("%I:%M %p")
                                    mixed_ml     = int(latest.get("ml", 0))
                                    countdown_end = latest_dt.timestamp() + countdown_secs
                                except (ValueError, AttributeError, KeyError):
                                    countdown_end = 0.0; mixed_at_str = ""; mixed_ml = 0
                            else:
                                countdown_end = 0.0; mixed_at_str = ""; mixed_ml = 0
                    log_selected = -1
                    log_back_btn.rect = pygame.Rect(0, H - 100, W // 2, 100)
                    btn_changed = True
                elif event.type == pygame.MOUSEBUTTONUP:
                    filtered = _filter_log_by_date(mix_log, log_view_date)
                    dy = (event.pos[1] - log_drag_start[1]) if log_drag_start else 0
                    log_drag_start = None
                    if abs(dy) > 30:  # swipe gesture
                        max_scroll = max(0, len(filtered) - LOG_MAX_SHOW)
                        if dy < 0:  # swipe up → scroll forward (older entries)
                            log_scroll = min(log_scroll + 1, max_scroll)
                        else:       # swipe down → scroll back (newer entries)
                            log_scroll = max(log_scroll - 1, 0)
                        btn_changed = True
                elif event.type == pygame.MOUSEBUTTONDOWN:
                    filtered = _filter_log_by_date(mix_log, log_view_date)
                    for card_rect, real_idx in _log_card_rects(filtered, log_scroll):
                        if card_rect.collidepoint(event.pos):
                            log_selected = real_idx
                            log_back_btn.rect = pygame.Rect(0, H - 100, W // 3, 100)
                            btn_changed = True
                            break

            elif mode == AppMode.TRENDS:
                if trends_back_btn.handle_event(event):
                    mode = AppMode.LOG
                    mix_log = api_client.get_log()
                    btn_changed = True
                else:
                    for ti, tb in enumerate(trend_range_btns):
                        if tb.handle_event(event):
                            trend_range_idx = ti
                            btn_changed = True
                            break

            elif mode == AppMode.CALCULATOR:
                if calc_plus_btn.handle_event(event):
                    calc_water_ml = min(calc_water_ml + 10, 500)
                    btn_changed = True
                elif calc_minus_btn.handle_event(event):
                    calc_water_ml = max(calc_water_ml - 10, 0)
                    btn_changed = True
                elif calc_back_btn.handle_event(event):
                    mode        = AppMode.MAIN
                    btn_changed = True
                elif calc_timer_btn.handle_event(event):
                    mode          = AppMode.MAIN
                    countdown_end = time.time() + countdown_secs
                    mixed_at_str  = datetime.now().strftime("%I:%M %p")
                    mixed_ml      = calc_water_ml
                    mix_log = load_log()
                    api_client.start_timer_async(calc_water_ml)
                    ntfy_sent     = False
                    btn_changed   = True

        # Expiry notification is handled server-side via GET /api/state
        # Just update local expired state for display
        if countdown_end > 0 and not ntfy_sent and time.time() > countdown_end:
            ntfy_sent = True

        # Screensaver activation (only from MAIN mode)
        if mode == AppMode.MAIN and \
                time.monotonic() - last_input > ss_timeout_min * 60:
            pre_ss_mode = mode
            mode = AppMode.SCREENSAVER
            last_frame_key = None

        # Screensaver animation
        if mode == AppMode.SCREENSAVER:
            for sp in ss_sprites:
                sp[0] += sp[2]  # x += dx
                sp[1] += sp[3]  # y += dy
                img = sp[6]()
                hw = img.get_width() // 2 - 3
                hh = img.get_height() // 2 - 3
                if sp[0] - hw <= 0:
                    sp[2] = abs(sp[2])
                    sp[4] = not sp[4]
                    sp[0] = hw
                elif sp[0] + hw >= W:
                    sp[2] = -abs(sp[2])
                    sp[4] = not sp[4]
                    sp[0] = W - hw
                if sp[1] - hh <= 0:
                    sp[3] = abs(sp[3])
                    sp[5] = not sp[5]
                    sp[1] = hh
                elif sp[1] + hh >= H:
                    sp[3] = -abs(sp[3])
                    sp[5] = not sp[5]
                    sp[1] = H - hh
            render_screensaver(surf,
                               [(s[0], s[1], s[4], s[5], s[6]) for s in ss_sprites])
            if simulate and not fullscreen:
                win.blit(surf, (0, 0))
                pygame.display.flip()
            last_frame_key = None
            clock.tick(FPS)
            continue

        # Apply any state update delivered by the background poll thread
        bg = _bg_cloud.get()
        if bg is not None:
            cloud_end = bg.get("countdown_end", 0.0)
            cloud_mix = bg.get("mixed_at_str", "")
            if cloud_end != countdown_end or cloud_mix != mixed_at_str:
                countdown_end = cloud_end
                mixed_at_str  = bg.get("mixed_at_str", "")
                mixed_ml      = bg.get("mixed_ml", 0)
                ntfy_sent     = bg.get("ntfy_sent", False)
                last_frame_key = None
            mix_log = bg.get("mix_log", mix_log)
            cloud_settings = bg.get("settings", {})
            new_cd = cloud_settings.get("countdown_secs", countdown_secs)
            new_ss = cloud_settings.get("ss_timeout_min", ss_timeout_min)
            if new_cd != countdown_secs or new_ss != ss_timeout_min:
                countdown_secs = new_cd
                ss_timeout_min = new_ss
                last_frame_key = None

        # Dirty-check to skip identical frames
        if mode == AppMode.MAIN:
            cd_remaining = countdown_end - time.time() if countdown_end > 0 else -1
            cd_expired = countdown_end > 0 and cd_remaining <= 0
            cd_sec = 0 if cd_expired else int(max(0, cd_remaining))
            frame_key = (mode, mixed_at_str, cd_sec, cd_expired) + tuple(b.pressed for b in main_btns)
        elif mode == AppMode.SAMPLES:
            frame_key = (mode, samples_back_btn.pressed)
        elif mode == AppMode.LOG:
            frame_key = (mode, len(mix_log), log_back_btn.pressed, log_selected,
                         numpad_active, numpad_value, log_view_date,
                         log_leftover_btn.pressed, log_delete_btn.pressed,
                         log_prev_btn.pressed, log_next_btn.pressed,
                         log_trends_btn.pressed)
        elif mode == AppMode.CALCULATOR:
            frame_key = (mode, calc_water_ml, calc_plus_btn.pressed,
                         calc_minus_btn.pressed, calc_back_btn.pressed,
                         calc_timer_btn.pressed)
        elif mode == AppMode.TRENDS:
            frame_key = (mode, trend_range_idx, len(mix_log),
                         trends_back_btn.pressed,
                         tuple(b.pressed for b in trend_range_btns))
        else:
            frame_key = None

        if frame_key != last_frame_key or btn_changed:
            if mode == AppMode.MAIN:
                render_main(surf, main_btns, mixed_at_str, countdown_end, mixed_ml, countdown_secs)
            elif mode == AppMode.SAMPLES:
                render_samples(surf, samples_back_btn)
            elif mode == AppMode.LOG:
                render_log(surf, mix_log, log_back_btn, log_selected,
                          log_leftover_btn, log_delete_btn,
                          log_prev_btn, log_next_btn, log_view_date,
                          trends_btn=log_trends_btn, log_scroll=log_scroll)
                if numpad_active:
                    render_numpad(surf, "Enter Leftover (ml)", numpad_value)
            elif mode == AppMode.CALCULATOR:
                render_calculator(surf, calc_water_ml,
                                  calc_plus_btn, calc_minus_btn,
                                  calc_back_btn, calc_timer_btn)
            elif mode == AppMode.TRENDS:
                render_trends(surf, mix_log, trend_range_btns,
                              trend_range_idx, trends_back_btn)


            # Debug overlay: last touch position at top-center
            if _dbg_pos:
                tx, ty = _dbg_pos
                target = win if (simulate and not fullscreen) else surf
                pygame.draw.circle(target, (255, 0, 0), (tx, ty), 14, 3)
                lbl = font(18).render(f"({tx},{ty})", True, (255, 255, 0))
                bg = pygame.Surface((lbl.get_width() + 8, lbl.get_height() + 4))
                bg.fill((0, 0, 0))
                target.blit(bg, (W // 2 - bg.get_width() // 2, 0))
                target.blit(lbl, (W // 2 - lbl.get_width() // 2, 2))
                pygame.display.flip()

            if simulate and not fullscreen:
                win.blit(surf, (0, 0))
                hint = font(13).render("Q quit", True, (80, 80, 100))
                win.blit(hint, (6, H - hint.get_height() - 3))
                pygame.display.flip()

            last_frame_key = frame_key

        clock.tick(FPS)

    pygame.quit()


def start_web_server(port: int = 5000) -> None:
    """Start the Flask web server as a daemon thread."""
    from formula_web import app
    def _run():
        import logging
        log = logging.getLogger("werkzeug")
        log.setLevel(logging.WARNING)
        app.run(host="0.0.0.0", port=port, debug=False, use_reloader=False)
    t = threading.Thread(target=_run, daemon=True)
    t.start()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Baby formula mixing assistant")
    parser.add_argument("--fullscreen", "-f", action="store_true",
                        help="Run fullscreen (recommended on RPi)")
    parser.add_argument("--simulate", "-s", action="store_true",
                        help="Windowed dev mode")
    parser.add_argument("--port", "-p", type=int, default=5000,
                        help="Web server port (default 5000)")
    parser.add_argument("--no-web", action="store_true",
                        help="Disable the web server")
    args = parser.parse_args()
    if not args.no_web:
        start_web_server(args.port)
    main(args.fullscreen, args.simulate)
