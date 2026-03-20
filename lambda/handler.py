"""
Formula Helper — AWS Lambda API handler.

Single Lambda function dispatched by API Gateway HTTP API route keys.
All state lives in DynamoDB table (env var TABLE_NAME).
"""

import json
import os
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from decimal import Decimal

# Central Time — use TZ env var for automatic DST handling
import zoneinfo
CT = zoneinfo.ZoneInfo("America/Chicago")

def _now_ct():
    return datetime.now(CT)

import base64
import secrets

import boto3
from boto3.dynamodb.conditions import Key

import webauthn
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    ResidentKeyRequirement,
    UserVerificationRequirement,
    AuthenticatorAttachment,
)
from webauthn.helpers import bytes_to_base64url, base64url_to_bytes

# ── Constants ────────────────────────────────────────────────────────────────
TABLE_NAME = os.environ.get("TABLE_NAME", "FormulaHelper")
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "bottle-expiry-1737")
PI_API_KEY = os.environ.get("PI_API_KEY", "")
VAPID_PRIVATE_KEY = os.environ.get("VAPID_PRIVATE_KEY", "")
VAPID_PUBLIC_KEY = os.environ.get("VAPID_PUBLIC_KEY", "")
VAPID_CLAIMS_EMAIL = "mailto:admin@formulahelper.app"
RP_ID = os.environ.get("RP_ID", "d20oyc88hlibbe.cloudfront.net")
RP_NAME = "Formula Helper"
RP_ORIGIN = os.environ.get("RP_ORIGIN", "https://d20oyc88hlibbe.cloudfront.net")
SESSION_TTL_SECS = 30 * 24 * 3600  # 30 days
DEFAULT_COUNTDOWN_SECS = 65 * 60  # 65 minutes

POWDER_PER_60ML = 8.3
COMBOS = [
    (60,  POWDER_PER_60ML),
    (80,  POWDER_PER_60ML * 80  / 60.0),
    (90,  POWDER_PER_60ML * 90  / 60.0),
    (100, POWDER_PER_60ML * 100 / 60.0),
]

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)

# ── Helpers ──────────────────────────────────────────────────────────────────

def _json_response(body, status=200):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
        },
        "body": json.dumps(body, default=str),
    }


def _parse_body(event):
    body = event.get("body", "{}")
    if event.get("isBase64Encoded"):
        import base64
        body = base64.b64decode(body).decode()
    return json.loads(body) if body else {}


def _decimal_to_native(obj):
    """Recursively convert Decimal values from DynamoDB to int/float."""
    if isinstance(obj, Decimal):
        return int(obj) if obj == int(obj) else float(obj)
    if isinstance(obj, dict):
        return {k: _decimal_to_native(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_decimal_to_native(i) for i in obj]
    return obj


def _get_timer_state():
    resp = table.get_item(Key={"PK": "STATE", "SK": "TIMER"})
    item = resp.get("Item", {})
    return {
        "countdown_end": float(item.get("countdown_end", 0)),
        "mixed_at_str": item.get("mixed_at_str", ""),
        "mixed_ml": int(item.get("mixed_ml", 0)),
        "ntfy_sent": bool(item.get("ntfy_sent", False)),
    }


def _put_timer_state(countdown_end, mixed_at_str, mixed_ml, ntfy_sent):
    table.put_item(Item={
        "PK": "STATE",
        "SK": "TIMER",
        "countdown_end": Decimal(str(countdown_end)),
        "mixed_at_str": mixed_at_str,
        "mixed_ml": mixed_ml,
        "ntfy_sent": ntfy_sent,
    })


def _get_settings():
    resp = table.get_item(Key={"PK": "STATE", "SK": "SETTINGS"})
    item = resp.get("Item", {})
    return {
        "countdown_secs": int(item.get("countdown_secs", DEFAULT_COUNTDOWN_SECS)),
        "ss_timeout_min": int(item.get("ss_timeout_min", 2)),
    }


def _put_settings(settings):
    table.put_item(Item={
        "PK": "STATE",
        "SK": "SETTINGS",
        "countdown_secs": settings.get("countdown_secs", DEFAULT_COUNTDOWN_SECS),
        "ss_timeout_min": settings.get("ss_timeout_min", 2),
    })


def _get_all_log_entries():
    """Query all LOG entries, sorted by SK."""
    items = []
    resp = table.query(
        KeyConditionExpression=Key("PK").eq("LOG"),
        ScanIndexForward=True,
    )
    items.extend(resp.get("Items", []))
    while resp.get("LastEvaluatedKey"):
        resp = table.query(
            KeyConditionExpression=Key("PK").eq("LOG"),
            ScanIndexForward=True,
            ExclusiveStartKey=resp["LastEvaluatedKey"],
        )
        items.extend(resp.get("Items", []))
    return _decimal_to_native(items)


def _log_entry_to_api(item):
    """Convert DynamoDB log item to API response format."""
    return {
        "sk": item["SK"],
        "text": item.get("text", ""),
        "leftover": item.get("leftover", ""),
        "ml": int(item.get("ml", 0)),
        "date": item.get("date", ""),
        "created_by": item.get("created_by", ""),
    }


def _send_ntfy(msg, title="Bottle Expired", mixed_at=""):
    """Send push notification via ntfy.sh."""
    import logging
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    ntfy_title = f"Bottle Expired - mixed at {mixed_at}" if mixed_at else title
    try:
        req = urllib.request.Request(
            f"https://ntfy.sh/{NTFY_TOPIC}",
            data=msg.encode(),
            headers={"Title": ntfy_title, "Priority": "high", "Tags": "baby_bottle"},
        )
        resp = urllib.request.urlopen(req, timeout=10)
        logger.info(f"ntfy sent: {resp.status} — {ntfy_title}")
    except Exception as e:
        logger.error(f"ntfy failed: {type(e).__name__}: {e}")


def _check_expiry_and_notify(timer_state):
    """Check if timer expired, send ntfy if not yet sent. Returns updated state."""
    countdown_end = timer_state["countdown_end"]
    if countdown_end <= 0:
        return timer_state

    remaining = max(0.0, countdown_end - time.time())
    expired = remaining <= 0

    if expired and not timer_state["ntfy_sent"]:
        # Atomic conditional update to prevent duplicate notifications
        import logging
        logging.getLogger().info(f"Timer expired, attempting to send notification for {timer_state['mixed_at_str']}")
        try:
            table.update_item(
                Key={"PK": "STATE", "SK": "TIMER"},
                UpdateExpression="SET ntfy_sent = :true",
                ConditionExpression="ntfy_sent = :false",
                ExpressionAttributeValues={":true": True, ":false": False},
            )
            _send_ntfy(
                "Formula has expired - discard the milk!",
                mixed_at=timer_state["mixed_at_str"],
            )
            timer_state["ntfy_sent"] = True
        except Exception:
            # ConditionalCheckFailedException or any other error — assume already sent
            timer_state["ntfy_sent"] = True

    # Also re-read ntfy_sent from DB to catch race conditions
    if expired:
        fresh = _get_timer_state()
        timer_state["ntfy_sent"] = fresh["ntfy_sent"]

    return timer_state


def _restore_state_from_log():
    """After deleting the latest entry, restore timer from the new latest."""
    entries = _get_all_log_entries()
    settings = _get_settings()
    countdown_secs = settings["countdown_secs"]

    if not entries:
        _put_timer_state(0.0, "", 0, False)
        return

    latest = entries[-1]
    date_str = latest.get("date", "")
    if not date_str:
        _put_timer_state(0.0, "", 0, False)
        return

    try:
        mixed_dt = datetime.strptime(date_str, "%Y-%m-%d %I:%M %p")
        mixed_at_str = mixed_dt.strftime("%I:%M %p")
        mixed_ml = int(latest.get("ml", 0))
        countdown_end = mixed_dt.timestamp() + countdown_secs
        expired = time.time() > countdown_end
        _put_timer_state(countdown_end, mixed_at_str, mixed_ml, expired)
    except (ValueError, KeyError):
        _put_timer_state(0.0, "", 0, False)


# ── Weekly notification ──────────────────────────────────────────────────────

def _compute_weekly_insights(entries):
    now = _now_ct()
    this_monday = (now - timedelta(days=now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0)
    last_monday = this_monday - timedelta(days=7)

    this_week = {"total_ml": 0, "bottles": 0, "days": set()}
    last_week = {"total_ml": 0, "bottles": 0, "days": set()}

    for e in entries:
        if not e.get("date") or not e.get("ml"):
            continue
        try:
            d = datetime.strptime(e["date"], "%Y-%m-%d %I:%M %p").replace(tzinfo=CT)
        except (ValueError, TypeError):
            continue
        ml = int(e["ml"])
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
    result["change_pct"] = round(change / last_week["total_ml"] * 100) if last_week["total_ml"] > 0 else None
    result["avg_change"] = result["this_week_avg"] - result["last_week_avg"]
    return result


def _check_weekly_notification(entries):
    current_week = _now_ct().strftime("%G-W%V")

    resp = table.get_item(Key={"PK": "STATE", "SK": "WEEKLY_NTFY"})
    item = resp.get("Item", {})
    if item.get("last_sent_week") == current_week:
        return

    insights = _compute_weekly_insights(entries)

    lines = []
    lines.append(f"This week: {insights['this_week_ml']}ml "
                 f"({insights['this_week_bottles']} bottles, "
                 f"avg {insights['this_week_avg']}ml/day)")
    if insights["last_week_ml"] > 0:
        sign = "+" if insights["change_ml"] >= 0 else ""
        pct = f" ({sign}{insights['change_pct']}%)" if insights["change_pct"] is not None else ""
        avg_sign = "+" if insights["avg_change"] >= 0 else ""
        lines.append(f"Last week: {insights['last_week_ml']}ml "
                     f"({insights['last_week_bottles']} bottles, "
                     f"avg {insights['last_week_avg']}ml/day)")
        lines.append(f"Change: {sign}{insights['change_ml']}ml{pct} | "
                     f"Avg/day: {avg_sign}{insights['avg_change']}ml")
    else:
        lines.append("No data from last week to compare.")

    msg = "\n".join(lines)
    try:
        _send_ntfy(msg, title="Weekly Summary")
        table.put_item(Item={
            "PK": "STATE",
            "SK": "WEEKLY_NTFY",
            "last_sent_week": current_week,
        })
    except Exception:
        pass


# ── Auth helpers ─────────────────────────────────────────────────────────────

def _get_session_from_event(event):
    """Extract session token from cookie header."""
    cookies = event.get("cookies", [])
    for c in cookies:
        if c.startswith("session="):
            return c.split("=", 1)[1]
    return None


def _validate_session(token):
    """Check if session token is valid and not expired. Returns session dict or None."""
    if not token:
        return None
    resp = table.get_item(Key={"PK": "AUTH", "SK": f"SESSION#{token}"})
    item = resp.get("Item")
    if not item:
        return None
    if time.time() > float(item.get("expires", 0)):
        table.delete_item(Key={"PK": "AUTH", "SK": f"SESSION#{token}"})
        return None
    return {"user_name": item.get("user_name", ""), "cred_id": item.get("cred_id", "")}


def _create_session(user_name="", cred_id=""):
    """Create a new session token and store in DynamoDB."""
    token = secrets.token_urlsafe(32)
    expires = time.time() + SESSION_TTL_SECS
    table.put_item(Item={
        "PK": "AUTH",
        "SK": f"SESSION#{token}",
        "expires": int(expires),
        "user_name": user_name,
        "cred_id": cred_id,
    })
    return token, int(expires)


def _session_cookie(token, max_age):
    return f"session={token}; Path=/; Max-Age={max_age}; SameSite=Lax; Secure; HttpOnly"


def _get_credentials():
    """Get all registered passkey credentials."""
    resp = table.query(
        KeyConditionExpression=Key("PK").eq("AUTH") & Key("SK").begins_with("CRED#")
    )
    return resp.get("Items", [])


def _has_any_credentials():
    return len(_get_credentials()) > 0


def auth_status(event):
    """Check if user is authenticated and if any credentials are registered."""
    token = _get_session_from_event(event)
    session = _validate_session(token)
    has_creds = _has_any_credentials()
    return _json_response({
        "authenticated": session is not None,
        "registered": has_creds,
        "user_name": session["user_name"] if session else "",
    })


def auth_register_options(event):
    """Generate registration options for new passkey."""
    creds = _get_credentials()
    exclude_credentials = []
    for c in creds:
        exclude_credentials.append({
            "id": c["credential_id"],
            "type": "public-key",
        })

    options = webauthn.generate_registration_options(
        rp_id=RP_ID,
        rp_name=RP_NAME,
        user_id=b"formula-helper-user",
        user_name="admin",
        user_display_name="Formula Helper Admin",
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.PREFERRED,
            user_verification=UserVerificationRequirement.PREFERRED,
        ),
    )

    # Store challenge for verification
    challenge_b64 = bytes_to_base64url(options.challenge)
    table.put_item(Item={
        "PK": "AUTH",
        "SK": "CHALLENGE#registration",
        "challenge": challenge_b64,
        "expires": int(time.time()) + 300,
    })

    return _json_response(json.loads(webauthn.options_to_json(options)))


def auth_register_verify(event):
    """Verify registration response and store credential."""
    data = _parse_body(event)
    user_name = data.pop("user_name", "")

    # Get stored challenge
    resp = table.get_item(Key={"PK": "AUTH", "SK": "CHALLENGE#registration"})
    challenge_item = resp.get("Item")
    if not challenge_item or time.time() > float(challenge_item.get("expires", 0)):
        return _json_response({"error": "Challenge expired"}, 400)

    challenge = base64url_to_bytes(challenge_item["challenge"])

    try:
        verification = webauthn.verify_registration_response(
            credential=data,
            expected_challenge=challenge,
            expected_rp_id=RP_ID,
            expected_origin=RP_ORIGIN,
        )
    except Exception as e:
        return _json_response({"error": str(e)}, 400)

    # Store credential with user name
    cred_id_b64 = bytes_to_base64url(verification.credential_id)
    table.put_item(Item={
        "PK": "AUTH",
        "SK": f"CRED#{cred_id_b64}",
        "credential_id": cred_id_b64,
        "public_key": bytes_to_base64url(verification.credential_public_key),
        "sign_count": verification.sign_count,
        "user_name": user_name,
        "created": _now_ct().isoformat(),
    })

    # Clean up challenge
    table.delete_item(Key={"PK": "AUTH", "SK": "CHALLENGE#registration"})

    # Create session with user name
    token, expires = _create_session(user_name=user_name, cred_id=cred_id_b64)
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "cookies": [_session_cookie(token, SESSION_TTL_SECS)],
        "body": json.dumps({"ok": True}),
    }


def auth_login_options(event):
    """Generate authentication options for existing passkey."""
    creds = _get_credentials()
    allow_credentials = []
    for c in creds:
        allow_credentials.append({
            "id": base64url_to_bytes(c["credential_id"]),
            "type": "public-key",
        })

    options = webauthn.generate_authentication_options(
        rp_id=RP_ID,
        allow_credentials=allow_credentials if allow_credentials else None,
        user_verification=UserVerificationRequirement.PREFERRED,
    )

    challenge_b64 = bytes_to_base64url(options.challenge)
    table.put_item(Item={
        "PK": "AUTH",
        "SK": "CHALLENGE#authentication",
        "challenge": challenge_b64,
        "expires": int(time.time()) + 300,
    })

    return _json_response(json.loads(webauthn.options_to_json(options)))


def auth_login_verify(event):
    """Verify authentication response and create session."""
    data = _parse_body(event)

    # Get stored challenge
    resp = table.get_item(Key={"PK": "AUTH", "SK": "CHALLENGE#authentication"})
    challenge_item = resp.get("Item")
    if not challenge_item or time.time() > float(challenge_item.get("expires", 0)):
        return _json_response({"error": "Challenge expired"}, 400)

    challenge = base64url_to_bytes(challenge_item["challenge"])

    # Find the credential
    cred_id_b64 = data.get("id", "")
    resp = table.get_item(Key={"PK": "AUTH", "SK": f"CRED#{cred_id_b64}"})
    cred_item = resp.get("Item")
    if not cred_item:
        return _json_response({"error": "Unknown credential"}, 400)

    try:
        verification = webauthn.verify_authentication_response(
            credential=data,
            expected_challenge=challenge,
            expected_rp_id=RP_ID,
            expected_origin=RP_ORIGIN,
            credential_public_key=base64url_to_bytes(cred_item["public_key"]),
            credential_current_sign_count=int(cred_item.get("sign_count", 0)),
        )
    except Exception as e:
        return _json_response({"error": str(e)}, 400)

    # Update sign count
    table.update_item(
        Key={"PK": "AUTH", "SK": f"CRED#{cred_id_b64}"},
        UpdateExpression="SET sign_count = :sc",
        ExpressionAttributeValues={":sc": verification.new_sign_count},
    )

    # Clean up challenge
    table.delete_item(Key={"PK": "AUTH", "SK": "CHALLENGE#authentication"})

    # Create session with user name from credential
    user_name = cred_item.get("user_name", "")
    token, expires = _create_session(user_name=user_name, cred_id=cred_id_b64)
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "cookies": [_session_cookie(token, SESSION_TTL_SECS)],
        "body": json.dumps({"ok": True, "user_name": user_name}),
    }


# ── Push subscription handlers ───────────────────────────────────────────────

def push_subscribe(event):
    """Store a push subscription."""
    data = _parse_body(event)
    sub = data.get("subscription")
    user_name = data.get("user_name", "")
    if not sub or not sub.get("endpoint"):
        return _json_response({"ok": False, "error": "invalid subscription"}, 400)

    # Use endpoint hash as unique ID
    import hashlib
    sub_id = hashlib.sha256(sub["endpoint"].encode()).hexdigest()[:16]

    table.put_item(Item={
        "PK": "PUSH",
        "SK": f"SUB#{sub_id}",
        "subscription": json.dumps(sub),
        "user_name": user_name,
        "created": _now_ct().isoformat(),
    })
    return _json_response({"ok": True})


def push_unsubscribe(event):
    """Remove a push subscription."""
    data = _parse_body(event)
    endpoint = data.get("endpoint", "")
    if not endpoint:
        return _json_response({"ok": False, "error": "missing endpoint"}, 400)

    import hashlib
    sub_id = hashlib.sha256(endpoint.encode()).hexdigest()[:16]
    table.delete_item(Key={"PK": "PUSH", "SK": f"SUB#{sub_id}"})
    return _json_response({"ok": True})


def push_vapid_key(event):
    """Return the VAPID public key for the client."""
    return _json_response({"publicKey": VAPID_PUBLIC_KEY})


# ── Route handlers ───────────────────────────────────────────────────────────

def get_state(event):
    timer_state = _get_timer_state()
    settings = _get_settings()
    entries = _get_all_log_entries()

    timer_state = _check_expiry_and_notify(timer_state)

    countdown_end = timer_state["countdown_end"]
    remaining = max(0.0, countdown_end - time.time()) if countdown_end > 0 else -1
    expired = countdown_end > 0 and remaining <= 0

    mix_log = [_log_entry_to_api(e) for e in entries]

    return _json_response({
        "countdown_end": countdown_end,
        "mixed_at_str": timer_state["mixed_at_str"],
        "mixed_ml": timer_state["mixed_ml"],
        "remaining_secs": max(0, remaining),
        "expired": expired,
        "ntfy_sent": timer_state["ntfy_sent"],
        "mix_log": mix_log,
        "settings": settings,
        "combos": [[w, round(p, 2)] for w, p in COMBOS],
        "powder_per_60": POWDER_PER_60ML,
    })


def post_start(event):
    data = _parse_body(event)
    ml = int(data.get("ml", 60))
    settings = _get_settings()
    countdown_secs = settings["countdown_secs"]

    # Get user name from session, or "Pi" if using API key
    token = _get_session_from_event(event)
    session = _validate_session(token)
    if session:
        user_name = session["user_name"]
    elif event.get("headers", {}).get("x-api-key") == PI_API_KEY:
        user_name = "Pi"
    else:
        user_name = ""

    now = _now_ct()
    countdown_end = time.time() + countdown_secs
    mixed_at_str = now.strftime("%I:%M %p")
    date_str = now.strftime("%Y-%m-%d %I:%M %p")
    sk = now.strftime("%Y-%m-%d") + "#" + f"{time.time():.3f}"

    table.put_item(Item={
        "PK": "LOG",
        "SK": sk,
        "text": f"{ml}ml @ {mixed_at_str}",
        "leftover": "",
        "ml": ml,
        "date": date_str,
        "created_by": user_name,
    })

    _put_timer_state(countdown_end, mixed_at_str, ml, False)

    # Check weekly notification
    try:
        entries = _get_all_log_entries()
        _check_weekly_notification(entries)
    except Exception:
        pass

    return _json_response({"ok": True, "sk": sk})


def put_log(event):
    sk = event.get("pathParameters", {}).get("sk", "")
    if not sk:
        return _json_response({"ok": False, "error": "missing sk"}, 400)

    data = _parse_body(event)
    update_expr_parts = []
    expr_values = {}

    if "text" in data:
        update_expr_parts.append("#t = :text")
        expr_values[":text"] = data["text"]
    if "leftover" in data:
        update_expr_parts.append("leftover = :leftover")
        expr_values[":leftover"] = data["leftover"]
    if "ml" in data:
        update_expr_parts.append("ml = :ml")
        expr_values[":ml"] = int(data["ml"])
    if "date" in data:
        update_expr_parts.append("#d = :date")
        expr_values[":date"] = data["date"]

    if not update_expr_parts:
        return _json_response({"ok": False, "error": "nothing to update"}, 400)

    expr_names = {}
    if any("#t" in p for p in update_expr_parts):
        expr_names["#t"] = "text"
    if any("#d" in p for p in update_expr_parts):
        expr_names["#d"] = "date"

    try:
        update_kwargs = {
            "Key": {"PK": "LOG", "SK": sk},
            "UpdateExpression": "SET " + ", ".join(update_expr_parts),
            "ExpressionAttributeValues": expr_values,
            "ConditionExpression": "attribute_exists(PK)",
        }
        if expr_names:
            update_kwargs["ExpressionAttributeNames"] = expr_names
        table.update_item(**update_kwargs)
    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return _json_response({"ok": False, "error": "entry not found"}, 404)

    return _json_response({"ok": True})


def delete_log(event):
    sk = event.get("pathParameters", {}).get("sk", "")
    if not sk:
        return _json_response({"ok": False, "error": "missing sk"}, 400)

    # Check if this is the latest entry
    entries = _get_all_log_entries()
    is_latest = entries and entries[-1].get("SK") == sk

    table.delete_item(Key={"PK": "LOG", "SK": sk})

    if is_latest:
        _restore_state_from_log()

    return _json_response({"ok": True})


def post_reset_timer(event):
    _put_timer_state(0.0, "", 0, False)
    return _json_response({"ok": True})


def post_settings(event):
    data = _parse_body(event)
    settings = _get_settings()

    if "countdown_secs" in data:
        settings["countdown_secs"] = int(data["countdown_secs"])
    if "ss_timeout_min" in data:
        settings["ss_timeout_min"] = int(data["ss_timeout_min"])

    _put_settings(settings)
    return _json_response({"ok": True, "settings": settings})


# ── Lambda entry point ───────────────────────────────────────────────────────

# Auth routes (no session required)
AUTH_ROUTES = {
    "GET /api/auth/status": auth_status,
    "POST /api/auth/register-options": auth_register_options,
    "POST /api/auth/register-verify": auth_register_verify,
    "POST /api/auth/login-options": auth_login_options,
    "POST /api/auth/login-verify": auth_login_verify,
}

# Protected routes (session required)
PROTECTED_ROUTES = {
    "GET /api/state": get_state,
    "POST /api/start": post_start,
    "PUT /api/log/{sk}": put_log,
    "DELETE /api/log/{sk}": delete_log,
    "POST /api/reset-timer": post_reset_timer,
    "POST /api/settings": post_settings,
}


def lambda_handler(event, context):
    route_key = event.get("routeKey", "")

    # Auth routes — no session needed
    if route_key in AUTH_ROUTES:
        try:
            return AUTH_ROUTES[route_key](event)
        except Exception as e:
            return _json_response({"error": str(e)}, 500)

    # Protected routes — require valid session
    handler = PROTECTED_ROUTES.get(route_key)
    if not handler:
        return _json_response({"error": f"Unknown route: {route_key}"}, 404)

    # Check authentication (skip if no credentials registered yet — first-time setup)
    if _has_any_credentials():
        # Allow Pi access via API key header
        api_key = event.get("headers", {}).get("x-api-key", "")
        if PI_API_KEY and api_key == PI_API_KEY:
            pass  # Pi is authorized
        else:
            token = _get_session_from_event(event)
            if not _validate_session(token):
                return _json_response({"error": "Unauthorized"}, 401)

    try:
        return handler(event)
    except Exception as e:
        return _json_response({"error": str(e)}, 500)
