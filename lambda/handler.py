"""
Formula Helper — DEV auth rewrite (dev_auth branch).

Multi-household model with passkey login + Sign in with Apple as recovery identity.
Scoped per-household data. Invite-token signup flow.

Routes are dispatched on (method, rawPath) with {param} support.
"""

import base64
import json
import os
import re
import secrets
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

import jwt
from jwt import PyJWKClient


# ── Config ───────────────────────────────────────────────────────────────────

TABLE_NAME = os.environ.get("TABLE_NAME", "FormulaHelper-dev")
RP_ID = os.environ.get("RP_ID", "")
RP_NAME = os.environ.get("RP_NAME", "Formula Helper")
RP_ORIGIN = os.environ.get("RP_ORIGIN", "")
STAGE = os.environ.get("STAGE", "dev")

# Sign in with Apple
SIWA_ISSUER = "https://appleid.apple.com"
SIWA_JWKS_URL = "https://appleid.apple.com/auth/keys"
SIWA_AUDIENCE = os.environ.get("SIWA_AUDIENCE", "com.ashokteja.formulahelper")

# TTLs
SESSION_TTL_SECS = 30 * 24 * 3600
CHALLENGE_TTL_SECS = 5 * 60
INVITE_TTL_SECS = 7 * 24 * 3600

# Defaults for new households
DEFAULT_COUNTDOWN_SECS = 65 * 60
DEFAULT_PRESET1 = 90
DEFAULT_PRESET2 = 120

POWDER_PER_60ML = 8.3
COMBOS = [
    (90, POWDER_PER_60ML * 90 / 60.0),
    (100, POWDER_PER_60ML * 100 / 60.0),
    (120, POWDER_PER_60ML * 120 / 60.0),
]

# ── Globals ──────────────────────────────────────────────────────────────────

_dynamodb = boto3.resource("dynamodb")
table = _dynamodb.Table(TABLE_NAME)
_jwk_client = PyJWKClient(SIWA_JWKS_URL, cache_keys=True, lifespan=3600)

# ── Small utilities ──────────────────────────────────────────────────────────

def _now() -> int:
    return int(time.time())

def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()

def _new_id(prefix: str = "") -> str:
    return f"{prefix}{secrets.token_urlsafe(16)}"

def _decimal_to_native(obj):
    if isinstance(obj, Decimal):
        return int(obj) if obj == int(obj) else float(obj)
    if isinstance(obj, dict):
        return {k: _decimal_to_native(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_decimal_to_native(i) for i in obj]
    return obj

def _parse_body(event: dict) -> dict:
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    return json.loads(body) if body else {}

def _json(body, status=200, cookies=None):
    resp = {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(body, default=str),
    }
    if cookies:
        resp["cookies"] = cookies
    return resp

def _session_cookie(token: str, max_age: int = SESSION_TTL_SECS) -> str:
    return f"session={token}; Path=/; Max-Age={max_age}; SameSite=Lax; Secure; HttpOnly"

def _clear_session_cookie() -> str:
    return "session=; Path=/; Max-Age=0; SameSite=Lax; Secure; HttpOnly"

# ── Session / auth context ───────────────────────────────────────────────────

def _session_token_from_event(event: dict) -> str | None:
    for c in event.get("cookies", []) or []:
        if c.startswith("session="):
            return c.split("=", 1)[1]
    return None

def _load_session(token: str | None) -> dict | None:
    if not token:
        return None
    item = table.get_item(Key={"PK": f"SESS#{token}", "SK": "META"}).get("Item")
    if not item or item.get("expires", 0) < _now():
        return None
    return _decimal_to_native(item)

def _create_session(user_id: str, active_hh: str | None) -> tuple[str, int]:
    token = _new_id()
    expires = _now() + SESSION_TTL_SECS
    table.put_item(Item={
        "PK": f"SESS#{token}",
        "SK": "META",
        "user_id": user_id,
        "active_hh": active_hh or "",
        "expires": expires,
        "ttl": expires + 24 * 3600,  # DynamoDB TTL sweeps after grace period
    })
    return token, expires

def _delete_session(token: str):
    table.delete_item(Key={"PK": f"SESS#{token}", "SK": "META"})

def _require_session(event: dict):
    """Returns session dict or an error response."""
    token = _session_token_from_event(event)
    s = _load_session(token)
    if not s:
        return None, _json({"error": "Unauthorized"}, 401)
    return s, None

def _require_member(session: dict, hh_id: str, allow_deleted: bool = False):
    """Verify session.user_id is a member of hh_id and, unless allow_deleted=True, that
    the household has not been soft-deleted. Returns (member_item, error_response).

    `allow_deleted=True` is reserved for escape paths like /leave that must succeed even
    on a tombstoned household so users can clear stale memberships from their session."""
    item = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": f"MEMBER#{session['user_id']}"}).get("Item")
    if not item:
        return None, _json({"error": "Forbidden"}, 403)
    if not allow_deleted:
        hh = _get_household(hh_id)
        if not hh or hh.get("deleted_at"):
            return None, _json({"error": "Household not found"}, 404)
    return _decimal_to_native(item), None

# Capability map — which roles can perform which actions. Add rows, don't migrate schema.
ROLE_CAPS: dict[str, set[str]] = {
    "owner":  {"invite", "kick", "change_role", "transfer_ownership", "delete_household", "log", "leave"},
    "admin":  {"invite", "kick", "log", "leave"},
    "member": {"log", "leave"},
}

def _can(role: str, action: str) -> bool:
    return action in ROLE_CAPS.get((role or "").lower(), set())

def _require_capability(session: dict, hh_id: str, action: str, allow_deleted: bool = False):
    """Returns (member_item, error_response). 403 if not a member or role lacks action.
    404 if household is soft-deleted (unless allow_deleted=True)."""
    member, err = _require_member(session, hh_id, allow_deleted=allow_deleted)
    if err:
        return None, err
    if not _can(member.get("role", ""), action):
        return None, _json({"error": "Forbidden"}, 403)
    return member, None

def _remove_membership(hh_id: str, user_id: str):
    """Drop both forward and mirror membership records."""
    table.delete_item(Key={"PK": f"USER#{user_id}", "SK": f"HH#{hh_id}"})
    table.delete_item(Key={"PK": f"HH#{hh_id}", "SK": f"MEMBER#{user_id}"})

def _update_membership_role(hh_id: str, user_id: str, role: str):
    """Update role on both forward and mirror records.

    Refuses to upsert ghost rows: existing membership records are required (otherwise
    a kicked user could be resurrected with a bare {role:...} item). Also enforces the
    role whitelist directly so a misbehaving caller can't stamp arbitrary strings."""
    if role not in ROLE_CAPS:
        raise ValueError(f"Invalid role: {role!r}")
    for key in ({"PK": f"USER#{user_id}", "SK": f"HH#{hh_id}"},
                {"PK": f"HH#{hh_id}", "SK": f"MEMBER#{user_id}"}):
        try:
            table.update_item(
                Key=key,
                UpdateExpression="SET #r = :r",
                ConditionExpression="attribute_exists(PK)",
                ExpressionAttributeNames={"#r": "role"},
                ExpressionAttributeValues={":r": role},
            )
        except table.meta.client.exceptions.ConditionalCheckFailedException:
            # Membership row missing — caller's _require_capability check should have caught it.
            # Skip silently rather than create a ghost.
            continue

# ── Challenges (per-session, short-lived) ────────────────────────────────────

def _put_challenge(challenge_b64: str, purpose: str, extra: dict | None = None) -> str:
    cid = _new_id("c_")
    item = {
        "PK": f"CHAL#{cid}",
        "SK": purpose,
        "challenge": challenge_b64,
        "purpose": purpose,
        "expires": _now() + CHALLENGE_TTL_SECS,
        "ttl": _now() + CHALLENGE_TTL_SECS + 60,
    }
    if extra:
        item.update(extra)
    table.put_item(Item=item)
    return cid

def _pop_challenge(cid: str, purpose: str) -> dict | None:
    item = table.get_item(Key={"PK": f"CHAL#{cid}", "SK": purpose}).get("Item")
    if not item:
        return None
    # One-shot — delete immediately
    table.delete_item(Key={"PK": f"CHAL#{cid}", "SK": purpose})
    if item.get("expires", 0) < _now():
        return None
    return _decimal_to_native(item)

# ── Sign in with Apple ───────────────────────────────────────────────────────

def _verify_siwa(id_token: str) -> dict:
    """Verify Apple identity token. Returns claims dict on success, raises on failure."""
    signing_key = _jwk_client.get_signing_key_from_jwt(id_token)
    claims = jwt.decode(
        id_token,
        signing_key.key,
        algorithms=["RS256"],
        audience=SIWA_AUDIENCE,
        issuer=SIWA_ISSUER,
    )
    if not claims.get("sub"):
        raise ValueError("SIWA token missing sub")
    return claims

# ── Users / credentials / apple_sub lookup ───────────────────────────────────

def _put_user(user_id: str, apple_sub: str, name: str, email: str | None = None):
    table.put_item(Item={
        "PK": f"USER#{user_id}",
        "SK": "PROFILE",
        "user_id": user_id,
        "apple_sub": apple_sub,
        "name": name,
        "email": email or "",
        "created_at": _iso_now(),
    })
    # Reverse lookup for recovery
    table.put_item(Item={
        "PK": f"APPLESUB#{apple_sub}",
        "SK": "LOOKUP",
        "user_id": user_id,
    })

def _get_user(user_id: str) -> dict | None:
    item = table.get_item(Key={"PK": f"USER#{user_id}", "SK": "PROFILE"}).get("Item")
    return _decimal_to_native(item) if item else None

def _user_id_for_apple_sub(apple_sub: str) -> str | None:
    item = table.get_item(Key={"PK": f"APPLESUB#{apple_sub}", "SK": "LOOKUP"}).get("Item")
    return item.get("user_id") if item else None

# ── Households / memberships ─────────────────────────────────────────────────

def _create_household(name: str, owner_uid: str, child_name: str = "", child_dob: str = "") -> str:
    hh_id = _new_id("h_")
    now = _iso_now()
    table.put_item(Item={
        "PK": f"HH#{hh_id}",
        "SK": "META",
        "hh_id": hh_id,
        "name": name,
        "owner_uid": owner_uid,
        "child_name": child_name,
        "child_dob": child_dob,
        "created_at": now,
    })
    _add_membership(hh_id, owner_uid, role="owner", hh_name=name)
    # Default settings
    table.put_item(Item={
        "PK": f"HH#{hh_id}",
        "SK": "SETTINGS",
        "countdown_secs": DEFAULT_COUNTDOWN_SECS,
        "preset1_ml": DEFAULT_PRESET1,
        "preset2_ml": DEFAULT_PRESET2,
        "ss_timeout_min": 2,
    })
    return hh_id

def _get_household(hh_id: str) -> dict | None:
    item = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": "META"}).get("Item")
    return _decimal_to_native(item) if item else None

def _add_membership(hh_id: str, user_id: str, role: str = "member", hh_name: str = ""):
    now = _iso_now()
    # Forward: USER#<uid> → HH#<hid>
    table.put_item(Item={
        "PK": f"USER#{user_id}",
        "SK": f"HH#{hh_id}",
        "hh_id": hh_id,
        "hh_name": hh_name,
        "role": role,
        "joined_at": now,
    })
    # Mirror: HH#<hid> → MEMBER#<uid>
    table.put_item(Item={
        "PK": f"HH#{hh_id}",
        "SK": f"MEMBER#{user_id}",
        "user_id": user_id,
        "role": role,
        "joined_at": now,
    })

def _list_memberships(user_id: str) -> list[dict]:
    resp = table.query(
        KeyConditionExpression=Key("PK").eq(f"USER#{user_id}") & Key("SK").begins_with("HH#"),
    )
    return [_decimal_to_native(i) for i in resp.get("Items", [])]

def _list_members(hh_id: str) -> list[dict]:
    resp = table.query(
        KeyConditionExpression=Key("PK").eq(f"HH#{hh_id}") & Key("SK").begins_with("MEMBER#"),
    )
    return [_decimal_to_native(i) for i in resp.get("Items", [])]

# ── Invites ──────────────────────────────────────────────────────────────────

def _create_invite(hh_id: str, hh_name: str, inviter_uid: str) -> dict:
    token = _new_id()
    expires = _now() + INVITE_TTL_SECS
    item = {
        "PK": f"INVITE#{token}",
        "SK": "META",
        "token": token,
        "hh_id": hh_id,
        "hh_name": hh_name,
        "inviter_uid": inviter_uid,
        "created_at": _iso_now(),
        "expires": expires,
        "ttl": expires + 24 * 3600,
        "used_at": "",
    }
    table.put_item(Item=item)
    return _decimal_to_native(item)

def _get_invite(token: str) -> dict | None:
    item = table.get_item(Key={"PK": f"INVITE#{token}", "SK": "META"}).get("Item")
    return _decimal_to_native(item) if item else None

def _consume_invite(token: str) -> dict | None:
    """Atomically mark invite used. Returns the invite dict, or None if already used / expired."""
    try:
        resp = table.update_item(
            Key={"PK": f"INVITE#{token}", "SK": "META"},
            UpdateExpression="SET used_at = :now",
            ConditionExpression="attribute_exists(PK) AND used_at = :empty AND expires > :t",
            ExpressionAttributeValues={":now": _iso_now(), ":empty": "", ":t": _now()},
            ReturnValues="ALL_NEW",
        )
        return _decimal_to_native(resp.get("Attributes"))
    except _dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return None

# ── Auth handlers ────────────────────────────────────────────────────────────

def auth_status(event):
    token = _session_token_from_event(event)
    session = _load_session(token)
    if not session:
        return _json({"authenticated": False})
    user = _get_user(session["user_id"])
    return _json({
        "authenticated": True,
        "user_id": session["user_id"],
        "user_name": (user or {}).get("name", ""),
        "active_hh": session.get("active_hh", ""),
    })

def auth_siwa(event):
    """Single auth endpoint — sign in or sign up via Sign in with Apple.

    Two-step flow:
      1. Client posts {siwa_id_token}. If the apple_sub already maps to a user,
         issue a session and return {returning: true}. If not, return 412 with
         a "needs" array describing the setup the client must collect.
      2. Client posts {siwa_id_token, user_name, household_name|invite_token,
         child_name?, child_dob?}. Server creates the user + household (or
         joins via invite), issues a session, returns {returning: false}.
    """
    data = _parse_body(event)
    siwa_token = (data.get("siwa_id_token") or "").strip()
    if not siwa_token:
        return _json({"error": "siwa_id_token required"}, 400)

    try:
        claims = _verify_siwa(siwa_token)
    except Exception as e:
        return _json({"error": f"SIWA verification failed: {e}"}, 400)

    apple_sub = claims["sub"]
    email_from_claim = claims.get("email") or ""

    # ── Returning user ────────────────────────────────────────────────────
    existing_uid = _user_id_for_apple_sub(apple_sub)
    if existing_uid:
        memberships = _list_memberships(existing_uid)
        active_hh = memberships[0]["hh_id"] if memberships else None
        token, _ = _create_session(existing_uid, active_hh=active_hh)
        print(f"[siwa] returning=True user_id={existing_uid} active_hh={active_hh}")
        return _json(
            {"ok": True, "user_id": existing_uid, "active_hh": active_hh, "returning": True},
            cookies=[_session_cookie(token)],
        )

    # ── First-time signup ─────────────────────────────────────────────────
    user_name = (data.get("user_name") or "").strip()
    household_name = (data.get("household_name") or "").strip()
    child_name = (data.get("child_name") or "").strip()
    child_dob = (data.get("child_dob") or "").strip()
    invite_token = (data.get("invite_token") or "").strip()

    # Setup-required: nothing in the body indicates how to provision the user.
    if not household_name and not invite_token:
        return _json(
            {
                "error": "Setup required",
                "returning": False,
                "needs": ["user_name", "household_name_or_invite_token"],
            },
            412,
        )

    if household_name and invite_token:
        return _json(
            {"error": "household_name and invite_token are mutually exclusive"},
            400,
        )

    # Resolve display name. SIWA's id_token does not normally carry the user's
    # name (Apple delivers it out-of-band via fullName on the iOS credential).
    # Try a `name` claim first as defense in depth, then fall back to body.
    resolved_name = ""
    name_claim = claims.get("name")
    if isinstance(name_claim, dict):
        first = (name_claim.get("firstName") or "").strip()
        last = (name_claim.get("lastName") or "").strip()
        resolved_name = " ".join(p for p in (first, last) if p)
    elif isinstance(name_claim, str):
        resolved_name = name_claim.strip()
    if not resolved_name:
        resolved_name = user_name
    if not resolved_name:
        return _json({"error": "user_name required on first signup"}, 400)

    # Mint the user.
    user_id = _new_id("u_")
    _put_user(user_id, apple_sub=apple_sub, name=resolved_name, email=email_from_claim)

    # Provision: invite or new household.
    if invite_token:
        invite = _get_invite(invite_token)
        if not invite or invite.get("used_at") or invite.get("expires", 0) < _now():
            # Roll back the just-created user so we don't leak orphans.
            table.delete_item(Key={"PK": f"USER#{user_id}", "SK": "PROFILE"})
            table.delete_item(Key={"PK": f"APPLESUB#{apple_sub}", "SK": "LOOKUP"})
            return _json({"error": "Invite is invalid or expired"}, 404)
        consumed = _consume_invite(invite_token)
        if not consumed:
            table.delete_item(Key={"PK": f"USER#{user_id}", "SK": "PROFILE"})
            table.delete_item(Key={"PK": f"APPLESUB#{apple_sub}", "SK": "LOOKUP"})
            return _json({"error": "Invite already used"}, 409)
        hh_id = consumed["hh_id"]
        _add_membership(hh_id, user_id, role="member", hh_name=consumed.get("hh_name", ""))
    else:
        hh_id = _create_household(
            household_name,
            owner_uid=user_id,
            child_name=child_name,
            child_dob=child_dob,
        )

    token, _ = _create_session(user_id, active_hh=hh_id)
    print(f"[siwa] returning=False user_id={user_id} active_hh={hh_id}")
    return _json(
        {"ok": True, "user_id": user_id, "active_hh": hh_id, "returning": False},
        cookies=[_session_cookie(token)],
    )

def auth_dev_login(event):
    """Dev-only backdoor: mint a session for a synthetic user without SIWA/passkey.
    The route itself is only registered on dev stages (see PUBLIC_ROUTES below);
    a runtime guard is kept as defense in depth in case the route table is mis-edited."""
    if STAGE != "dev":
        return _json({"error": "Not found"}, 404)

    user_id = "dev-sim-user"
    user = _get_user(user_id)
    if not user:
        _put_user(user_id, apple_sub="dev-sim", name="Sim User", email="sim@example.invalid")

    # Reuse an OWNED, NON-DELETED household if one exists; otherwise create a fresh
    # Sim Household so the dev user always lands as owner (owner-gated UI testing).
    hh_id = None
    for m in _list_memberships(user_id):
        if m.get("role") != "owner":
            continue
        hh = _get_household(m["hh_id"])
        if not hh or hh.get("deleted_at"):
            continue
        hh_id = m["hh_id"]
        break
    if hh_id is None:
        hh_id = _create_household(
            "Sim Household",
            owner_uid=user_id,
            child_name="Sim Baby",
            child_dob="2025-01-01",
        )

    token, _ = _create_session(user_id, active_hh=hh_id)
    return _json(
        {"ok": True, "user_id": user_id, "active_hh": hh_id},
        cookies=[_session_cookie(token)],
    )

def auth_logout(event):
    token = _session_token_from_event(event)
    if token:
        _delete_session(token)
    return _json({"ok": True}, cookies=[_clear_session_cookie()])

# ── Household handlers ───────────────────────────────────────────────────────

def households_list(event):
    session, err = _require_session(event)
    if err:
        return err
    memberships = _list_memberships(session["user_id"])
    # Filter out soft-deleted households
    out = []
    for m in memberships:
        hh = _get_household(m["hh_id"])
        if not hh or hh.get("deleted_at"):
            continue
        out.append({"hh_id": m["hh_id"], "name": m.get("hh_name", ""), "role": m.get("role", "")})
    return _json({"active_hh": session.get("active_hh", ""), "households": out})

def households_create(event):
    session, err = _require_session(event)
    if err:
        return err
    data = _parse_body(event)
    name = (data.get("name") or "").strip()
    if not name:
        return _json({"error": "name required"}, 400)
    hh_id = _create_household(name, owner_uid=session["user_id"])
    # Switch to new household
    token = _session_token_from_event(event)
    table.update_item(
        Key={"PK": f"SESS#{token}", "SK": "META"},
        UpdateExpression="SET active_hh = :h",
        ExpressionAttributeValues={":h": hh_id},
    )
    return _json({"ok": True, "hh_id": hh_id})

def households_switch(event):
    session, err = _require_session(event)
    if err:
        return err
    data = _parse_body(event)
    hh_id = (data.get("hh_id") or "").strip()
    if not hh_id:
        return _json({"error": "hh_id required"}, 400)
    _, mem_err = _require_member(session, hh_id)
    if mem_err:
        return mem_err
    token = _session_token_from_event(event)
    table.update_item(
        Key={"PK": f"SESS#{token}", "SK": "META"},
        UpdateExpression="SET active_hh = :h",
        ExpressionAttributeValues={":h": hh_id},
    )
    return _json({"ok": True, "active_hh": hh_id})

def household_members_list(event):
    session, err = _require_session(event)
    if err:
        return err
    hh_id = event.get("pathParameters", {}).get("hh_id", "")
    _, mem_err = _require_member(session, hh_id)
    if mem_err:
        return mem_err
    members = _list_members(hh_id)
    # Enrich with display name from USER profile
    out = []
    for m in members:
        u = _get_user(m["user_id"]) or {}
        out.append({
            "user_id": m["user_id"],
            "name": u.get("name", ""),
            "role": m.get("role", ""),
            "joined_at": m.get("joined_at", ""),
        })
    return _json({"members": out})

def household_member_update(event):
    """PUT /api/households/{hh_id}/members/{user_id} — change role. Owner only."""
    session, err = _require_session(event)
    if err:
        return err
    params = event.get("pathParameters", {}) or {}
    hh_id = params.get("hh_id", "")
    target_uid = params.get("user_id", "")
    _, cap_err = _require_capability(session, hh_id, "change_role")
    if cap_err:
        return cap_err
    data = _parse_body(event)
    new_role = (data.get("role") or "").strip()
    if new_role not in ROLE_CAPS:
        return _json({"error": "Invalid role"}, 400)
    if new_role == "owner":
        return _json({"error": "Use /transfer to make someone owner"}, 400)
    target = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": f"MEMBER#{target_uid}"}).get("Item")
    if not target:
        return _json({"error": "Member not found"}, 404)
    if target.get("role") == "owner":
        return _json({"error": "Cannot demote owner directly; transfer ownership first"}, 400)
    _update_membership_role(hh_id, target_uid, new_role)
    return _json({"ok": True})

def household_member_remove(event):
    """DELETE /api/households/{hh_id}/members/{user_id} — kick."""
    session, err = _require_session(event)
    if err:
        return err
    params = event.get("pathParameters", {}) or {}
    hh_id = params.get("hh_id", "")
    target_uid = params.get("user_id", "")
    actor, cap_err = _require_capability(session, hh_id, "kick")
    if cap_err:
        return cap_err
    if target_uid == session["user_id"]:
        return _json({"error": "Use /leave to remove yourself"}, 400)
    target = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": f"MEMBER#{target_uid}"}).get("Item")
    if not target:
        return _json({"error": "Member not found"}, 404)
    if target.get("role") == "owner":
        return _json({"error": "Cannot kick owner"}, 403)
    # Admin cannot kick another admin
    if actor.get("role") == "admin" and target.get("role") == "admin":
        return _json({"error": "Admins cannot kick other admins"}, 403)
    _remove_membership(hh_id, target_uid)
    return _json({"ok": True})

def household_leave(event):
    """POST /api/households/{hh_id}/leave — current user leaves. Owner must transfer or delete first.
    Permitted on soft-deleted households so users can shake stale memberships."""
    session, err = _require_session(event)
    if err:
        return err
    hh_id = (event.get("pathParameters", {}) or {}).get("hh_id", "")
    member, cap_err = _require_capability(session, hh_id, "leave", allow_deleted=True)
    if cap_err:
        return cap_err
    if member.get("role") == "owner":
        # Owner of an alive household must transfer/delete first. If the household
        # is already soft-deleted, allow the (formerly-)owner to leave like any member.
        hh = _get_household(hh_id) or {}
        if not hh.get("deleted_at"):
            return _json({"error": "Transfer ownership or delete the household before leaving"}, 400)
    _remove_membership(hh_id, session["user_id"])
    # If they were actively in this household, pick a next viable membership for them.
    if session.get("active_hh") == hh_id:
        next_hh = ""
        for m in _list_memberships(session["user_id"]):
            if m["hh_id"] == hh_id:
                continue
            hh = _get_household(m["hh_id"])
            if hh and not hh.get("deleted_at"):
                next_hh = m["hh_id"]
                break
        token = _session_token_from_event(event)
        table.update_item(
            Key={"PK": f"SESS#{token}", "SK": "META"},
            UpdateExpression="SET active_hh = :h",
            ExpressionAttributeValues={":h": next_hh},
        )
    return _json({"ok": True})

def household_transfer(event):
    """POST /api/households/{hh_id}/transfer — owner transfers ownership to another member.
    Current owner becomes admin. Atomic via TransactWriteItems so a partial failure can
    never leave the household with zero or two owners."""
    session, err = _require_session(event)
    if err:
        return err
    hh_id = (event.get("pathParameters", {}) or {}).get("hh_id", "")
    _, cap_err = _require_capability(session, hh_id, "transfer_ownership")
    if cap_err:
        return cap_err
    data = _parse_body(event)
    target_uid = (data.get("user_id") or "").strip()
    if not target_uid or target_uid == session["user_id"]:
        return _json({"error": "Invalid target"}, 400)
    target = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": f"MEMBER#{target_uid}"}).get("Item")
    if not target:
        return _json({"error": "Member not found"}, 404)
    if target.get("role") == "owner":
        return _json({"error": "Target is already owner"}, 400)

    caller_uid = session["user_id"]
    # Five conditional writes in a single transaction: promote target on both records,
    # demote caller on both records, update HH META owner_uid. Each row's update is
    # gated on its current role to make the transfer idempotent and race-safe.
    try:
        table.meta.client.transact_write_items(TransactItems=[
            {"Update": {
                "TableName": table.name,
                "Key": {"PK": {"S": f"USER#{target_uid}"}, "SK": {"S": f"HH#{hh_id}"}},
                "UpdateExpression": "SET #r = :owner",
                "ConditionExpression": "attribute_exists(PK) AND #r = :member_or_admin_t",
                "ExpressionAttributeNames": {"#r": "role"},
                "ExpressionAttributeValues": {
                    ":owner": {"S": "owner"},
                    ":member_or_admin_t": {"S": target.get("role", "member")},
                },
            }},
            {"Update": {
                "TableName": table.name,
                "Key": {"PK": {"S": f"HH#{hh_id}"}, "SK": {"S": f"MEMBER#{target_uid}"}},
                "UpdateExpression": "SET #r = :owner",
                "ConditionExpression": "attribute_exists(PK) AND #r = :member_or_admin_t",
                "ExpressionAttributeNames": {"#r": "role"},
                "ExpressionAttributeValues": {
                    ":owner": {"S": "owner"},
                    ":member_or_admin_t": {"S": target.get("role", "member")},
                },
            }},
            {"Update": {
                "TableName": table.name,
                "Key": {"PK": {"S": f"USER#{caller_uid}"}, "SK": {"S": f"HH#{hh_id}"}},
                "UpdateExpression": "SET #r = :admin",
                "ConditionExpression": "attribute_exists(PK) AND #r = :owner",
                "ExpressionAttributeNames": {"#r": "role"},
                "ExpressionAttributeValues": {
                    ":admin": {"S": "admin"},
                    ":owner": {"S": "owner"},
                },
            }},
            {"Update": {
                "TableName": table.name,
                "Key": {"PK": {"S": f"HH#{hh_id}"}, "SK": {"S": f"MEMBER#{caller_uid}"}},
                "UpdateExpression": "SET #r = :admin",
                "ConditionExpression": "attribute_exists(PK) AND #r = :owner",
                "ExpressionAttributeNames": {"#r": "role"},
                "ExpressionAttributeValues": {
                    ":admin": {"S": "admin"},
                    ":owner": {"S": "owner"},
                },
            }},
            {"Update": {
                "TableName": table.name,
                "Key": {"PK": {"S": f"HH#{hh_id}"}, "SK": {"S": "META"}},
                "UpdateExpression": "SET owner_uid = :u",
                "ConditionExpression": "owner_uid = :caller",
                "ExpressionAttributeValues": {
                    ":u": {"S": target_uid},
                    ":caller": {"S": caller_uid},
                },
            }},
        ])
    except table.meta.client.exceptions.TransactionCanceledException as e:
        return _json({"error": "Transfer failed — household state changed; refresh and try again"}, 409)
    return _json({"ok": True})

def household_delete(event):
    """DELETE /api/households/{hh_id} — soft-delete the household. Owner only."""
    session, err = _require_session(event)
    if err:
        return err
    hh_id = (event.get("pathParameters", {}) or {}).get("hh_id", "")
    _, cap_err = _require_capability(session, hh_id, "delete_household")
    if cap_err:
        return cap_err
    table.update_item(
        Key={"PK": f"HH#{hh_id}", "SK": "META"},
        UpdateExpression="SET deleted_at = :t",
        ExpressionAttributeValues={":t": _iso_now()},
    )
    # Clear active_hh on caller's session if pointing here
    if session.get("active_hh") == hh_id:
        token = _session_token_from_event(event)
        table.update_item(
            Key={"PK": f"SESS#{token}", "SK": "META"},
            UpdateExpression="SET active_hh = :e",
            ExpressionAttributeValues={":e": ""},
        )
    return _json({"ok": True})

# ── Invite handlers ──────────────────────────────────────────────────────────

def invite_preview(event):
    token = event.get("pathParameters", {}).get("token", "")
    inv = _get_invite(token)
    if not inv or inv.get("used_at") or inv.get("expires", 0) < _now():
        return _json({"error": "Invite is invalid or expired"}, 404)
    inviter = _get_user(inv["inviter_uid"]) or {}
    return _json({
        "hh_name": inv.get("hh_name", ""),
        "inviter_name": inviter.get("name", ""),
        "expires": inv.get("expires", 0),
    })

def invite_create(event):
    session, err = _require_session(event)
    if err:
        return err
    hh_id = session.get("active_hh") or ""
    if not hh_id:
        return _json({"error": "No active household"}, 400)
    _, cap_err = _require_capability(session, hh_id, "invite")
    if cap_err:
        return cap_err
    hh = _get_household(hh_id) or {}
    inv = _create_invite(hh_id, hh.get("name", ""), inviter_uid=session["user_id"])
    return _json({
        "token": inv["token"],
        "expires": inv["expires"],
        "hh_name": inv.get("hh_name", ""),
    })

def invite_redeem(event):
    """Existing logged-in user joins a new household via invite."""
    session, err = _require_session(event)
    if err:
        return err
    token = event.get("pathParameters", {}).get("token", "")
    inv = _get_invite(token)
    if not inv or inv.get("used_at") or inv.get("expires", 0) < _now():
        return _json({"error": "Invite is invalid or expired"}, 404)

    hh_id = inv["hh_id"]
    # Already a member?
    existing = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": f"MEMBER#{session['user_id']}"}).get("Item")
    if existing:
        return _json({"error": "Already a member of this household"}, 409)

    consumed = _consume_invite(token)
    if not consumed:
        return _json({"error": "Invite already used"}, 409)
    _add_membership(hh_id, session["user_id"], role="member", hh_name=inv.get("hh_name", ""))
    return _json({"ok": True, "hh_id": hh_id, "hh_name": inv.get("hh_name", "")})

# ── Household-scoped data (feedings / diapers / naps / settings / state) ─────

def _hh_settings(hh_id: str) -> dict:
    item = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": "SETTINGS"}).get("Item") or {}
    return {
        "countdown_secs": int(item.get("countdown_secs", DEFAULT_COUNTDOWN_SECS)),
        "preset1_ml": int(item.get("preset1_ml", DEFAULT_PRESET1)),
        "preset2_ml": int(item.get("preset2_ml", DEFAULT_PRESET2)),
        "ss_timeout_min": int(item.get("ss_timeout_min", 2)),
    }

def _hh_timer(hh_id: str) -> dict:
    item = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": "TIMER"}).get("Item") or {}
    return {
        "countdown_end": float(item.get("countdown_end", 0)),
        "mixed_at_str": item.get("mixed_at_str", ""),
        "mixed_ml": int(item.get("mixed_ml", 0)),
        "ntfy_sent": bool(item.get("ntfy_sent", False)),
    }

def _put_hh_timer(hh_id: str, countdown_end: float, mixed_at_str: str, mixed_ml: int, ntfy_sent: bool):
    table.put_item(Item={
        "PK": f"HH#{hh_id}",
        "SK": "TIMER",
        "countdown_end": Decimal(str(countdown_end)),
        "mixed_at_str": mixed_at_str,
        "mixed_ml": mixed_ml,
        "ntfy_sent": ntfy_sent,
    })

def _restore_hh_timer_from_log(hh_id: str):
    """Re-derive the household's TIMER row from the most recent FEED# entry.
    Called after every manual add / edit / delete of a feeding so the dashboard's
    countdown auto-tracks whichever entry is now most recent. If no feedings
    remain, clears the timer."""
    feedings = _query_hh_prefix(hh_id, "FEED#")
    if not feedings:
        _put_hh_timer(hh_id, 0.0, "", 0, False)
        return
    settings = _hh_settings(hh_id)
    countdown_secs = settings["countdown_secs"]
    parsed = []
    for f in feedings:
        try:
            dt = datetime.strptime(f.get("date", ""), "%Y-%m-%d %I:%M %p").replace(tzinfo=timezone.utc)
            parsed.append((f, dt))
        except (ValueError, TypeError):
            continue
    if not parsed:
        # No parseable dates — fall back to lex-last entry, anchor timer to "now".
        latest = feedings[-1]
        _put_hh_timer(hh_id, time.time() + countdown_secs,
                      latest.get("date", "").split(" ", 1)[-1] if " " in latest.get("date", "") else "",
                      int(latest.get("ml", 0)), False)
        return
    latest, latest_dt = max(parsed, key=lambda x: x[1])
    mixed_at_str = latest_dt.strftime("%I:%M %p").lstrip("0")
    mixed_ml = int(latest.get("ml", 0))
    countdown_end = latest_dt.timestamp() + countdown_secs
    _put_hh_timer(hh_id, countdown_end, mixed_at_str, mixed_ml, False)

def _query_hh_prefix(hh_id: str, prefix: str) -> list[dict]:
    items = []
    kwargs = {
        "KeyConditionExpression": Key("PK").eq(f"HH#{hh_id}") & Key("SK").begins_with(prefix),
        "ScanIndexForward": True,
    }
    while True:
        resp = table.query(**kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
    return [_decimal_to_native(i) for i in items]

def get_state(event):
    session, err = _require_session(event)
    if err:
        return err
    hh_id = session.get("active_hh") or ""
    if not hh_id:
        return _json({"error": "No active household"}, 400)
    _, mem_err = _require_member(session, hh_id)
    if mem_err:
        return mem_err

    settings = _hh_settings(hh_id)
    timer = _hh_timer(hh_id)
    feedings = [_feed_to_api(i) for i in _query_hh_prefix(hh_id, "FEED#")]
    diapers = [_diaper_to_api(i) for i in _query_hh_prefix(hh_id, "DIAPER#")]
    naps = [_nap_to_api(i) for i in _query_hh_prefix(hh_id, "NAP#")]

    remaining = max(0.0, timer["countdown_end"] - time.time()) if timer["countdown_end"] else 0.0
    expired = timer["countdown_end"] > 0 and remaining <= 0

    return _json({
        "countdown_end": timer["countdown_end"],
        "mixed_at_str": timer["mixed_at_str"],
        "mixed_ml": timer["mixed_ml"],
        "remaining_secs": remaining,
        "expired": expired,
        "ntfy_sent": timer["ntfy_sent"],
        "mix_log": feedings,
        "diaper_log": diapers,
        "nap_log": naps,
        "settings": settings,
        "combos": [[c[0], c[1]] for c in COMBOS],
        "powder_per_60": POWDER_PER_60ML,
        "weight_log": [],
    })

def _feed_to_api(item):
    return {
        "sk": item["SK"],
        "text": item.get("text", ""),
        "leftover": item.get("leftover", ""),
        "ml": int(item.get("ml", 0)),
        "date": item.get("date", ""),
        "created_by": item.get("created_by_name", ""),
    }

def _diaper_to_api(item):
    return {
        "sk": item["SK"],
        "type": item.get("type", ""),
        "date": item.get("date", ""),
        "created_by": item.get("created_by_name", ""),
    }

def _nap_to_api(item):
    out = {
        "sk": item["SK"],
        "date": item.get("date", ""),
        "created_by": item.get("created_by_name", ""),
    }
    if item.get("duration_mins") is not None:
        out["duration_mins"] = int(item["duration_mins"])
    return out

def _creator_name(session: dict) -> str:
    user = _get_user(session["user_id"])
    return (user or {}).get("name", "")

def post_start_feeding(event):
    session, err = _require_session(event)
    if err:
        return err
    hh_id = session.get("active_hh") or ""
    if not hh_id:
        return _json({"error": "No active household"}, 400)
    _, mem_err = _require_member(session, hh_id)
    if mem_err:
        return mem_err

    data = _parse_body(event)
    try:
        ml = int(data.get("ml", 0))
    except (TypeError, ValueError):
        return _json({"error": "invalid ml"}, 400)
    if ml <= 0:
        return _json({"error": "ml must be positive"}, 400)

    settings = _hh_settings(hh_id)
    now_utc = datetime.now(timezone.utc)
    mixed_at = now_utc.strftime("%I:%M %p").lstrip("0")
    countdown_end = time.time() + settings["countdown_secs"]

    sk = f"FEED#{now_utc.strftime('%Y%m%dT%H%M%S')}#{_new_id()[:6]}"
    date_str = now_utc.strftime("%Y-%m-%d %I:%M %p")
    table.put_item(Item={
        "PK": f"HH#{hh_id}",
        "SK": sk,
        "ml": ml,
        "leftover": "",
        "text": f"{ml}ml @ {mixed_at}",
        "date": date_str,
        "created_by_uid": session["user_id"],
        "created_by_name": _creator_name(session),
    })
    _put_hh_timer(hh_id, countdown_end, mixed_at, ml, False)
    return _json({"ok": True, "sk": sk})

def post_feeding(event):
    """Manual backfill of a feeding entry."""
    session, err = _require_session(event)
    if err:
        return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err:
        return mem_err

    data = _parse_body(event)
    ml = int(data.get("ml", 0))
    date_str = data.get("date", "").strip()
    leftover = data.get("leftover", "")
    if ml <= 0 or not date_str:
        return _json({"error": "ml and date required"}, 400)
    sk = f"FEED#{_backfill_sk(date_str)}"
    table.put_item(Item={
        "PK": f"HH#{hh_id}",
        "SK": sk,
        "ml": ml,
        "leftover": "".join(c for c in leftover if c.isdigit()),
        "text": data.get("text", f"{ml}ml"),
        "date": date_str,
        "created_by_uid": session["user_id"],
        "created_by_name": _creator_name(session),
    })
    # Re-anchor the household's timer to whichever feed is now the latest
    # (this one if it post-dates the previous most-recent, otherwise the
    # previous one — backfills don't disturb a fresher bottle's timer).
    _restore_hh_timer_from_log(hh_id)
    return _json({"ok": True, "sk": sk})

def put_feeding(event):
    session, err = _require_session(event)
    if err:
        return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err:
        return mem_err
    sk = event.get("pathParameters", {}).get("sk", "")
    if not sk:
        return _json({"error": "sk required"}, 400)
    data = _parse_body(event)
    updates = []
    values = {}
    names = {}
    if "ml" in data:
        updates.append("ml = :ml"); values[":ml"] = int(data["ml"])
    if "leftover" in data:
        updates.append("leftover = :lo"); values[":lo"] = "".join(c for c in str(data["leftover"]) if c.isdigit())
    if "text" in data:
        updates.append("#t = :t"); values[":t"] = data["text"]; names["#t"] = "text"
    if "date" in data:
        updates.append("#d = :d"); values[":d"] = data["date"]; names["#d"] = "date"
    if not updates:
        return _json({"error": "nothing to update"}, 400)
    kwargs = {
        "Key": {"PK": f"HH#{hh_id}", "SK": sk},
        "UpdateExpression": "SET " + ", ".join(updates),
        "ExpressionAttributeValues": values,
        "ConditionExpression": "attribute_exists(PK)",
    }
    if names:
        kwargs["ExpressionAttributeNames"] = names
    try:
        table.update_item(**kwargs)
    except _dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return _json({"error": "not found"}, 404)
    # An edit can change ml or date on any entry, including the most recent —
    # always re-derive the timer to keep the dashboard honest.
    _restore_hh_timer_from_log(hh_id)
    return _json({"ok": True})

def delete_feeding(event):
    session, err = _require_session(event)
    if err:
        return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err:
        return mem_err
    sk = event.get("pathParameters", {}).get("sk", "")
    table.delete_item(Key={"PK": f"HH#{hh_id}", "SK": sk})
    # Deleting the most recent feed should fall the timer back to the new
    # latest (or clear it if the household has no feedings left).
    _restore_hh_timer_from_log(hh_id)
    return _json({"ok": True})

def _backfill_sk(date_str: str) -> str:
    """Build a sortable SK suffix from a user-entered date string."""
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d %I:%M %p")
        return dt.strftime("%Y%m%dT%H%M%S") + f"#{_new_id()[:6]}"
    except ValueError:
        return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + f"#{_new_id()[:6]}"

def post_diaper(event):
    session, err = _require_session(event)
    if err: return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err: return mem_err
    data = _parse_body(event)
    dtype = (data.get("type") or "").strip().lower()
    if dtype not in ("pee", "poo"):
        return _json({"error": "type must be pee or poo"}, 400)
    date_str = data.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d %I:%M %p")
    sk = f"DIAPER#{_backfill_sk(date_str)}"
    table.put_item(Item={
        "PK": f"HH#{hh_id}", "SK": sk,
        "type": dtype, "date": date_str,
        "created_by_uid": session["user_id"],
        "created_by_name": _creator_name(session),
    })
    return _json({"ok": True, "sk": sk})

def put_diaper(event):
    session, err = _require_session(event)
    if err: return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err: return mem_err
    sk = event.get("pathParameters", {}).get("sk", "")
    data = _parse_body(event)
    updates, values, names = [], {}, {}
    if "type" in data:
        updates.append("#ty = :ty"); values[":ty"] = data["type"]; names["#ty"] = "type"
    if "date" in data:
        updates.append("#d = :d"); values[":d"] = data["date"]; names["#d"] = "date"
    if not updates:
        return _json({"error": "nothing to update"}, 400)
    try:
        table.update_item(
            Key={"PK": f"HH#{hh_id}", "SK": sk},
            UpdateExpression="SET " + ", ".join(updates),
            ExpressionAttributeValues=values,
            ExpressionAttributeNames=names,
            ConditionExpression="attribute_exists(PK)",
        )
    except _dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return _json({"error": "not found"}, 404)
    return _json({"ok": True})

def delete_diaper(event):
    session, err = _require_session(event)
    if err: return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err: return mem_err
    sk = event.get("pathParameters", {}).get("sk", "")
    table.delete_item(Key={"PK": f"HH#{hh_id}", "SK": sk})
    return _json({"ok": True})

def post_nap(event):
    session, err = _require_session(event)
    if err: return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err: return mem_err
    data = _parse_body(event)
    date_str = data.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d %I:%M %p")
    item = {
        "PK": f"HH#{hh_id}",
        "SK": f"NAP#{_backfill_sk(date_str)}",
        "date": date_str,
        "created_by_uid": session["user_id"],
        "created_by_name": _creator_name(session),
    }
    if data.get("duration_mins") is not None:
        try:
            item["duration_mins"] = int(data["duration_mins"])
        except (TypeError, ValueError):
            pass
    table.put_item(Item=item)
    return _json({"ok": True, "sk": item["SK"]})

def put_nap(event):
    session, err = _require_session(event)
    if err: return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err: return mem_err
    sk = event.get("pathParameters", {}).get("sk", "")
    data = _parse_body(event)
    updates, values, names = [], {}, {}
    if "date" in data:
        updates.append("#d = :d"); values[":d"] = data["date"]; names["#d"] = "date"
    if "duration_mins" in data:
        if data["duration_mins"] is None:
            updates.append("duration_mins = :nil"); values[":nil"] = None
        else:
            updates.append("duration_mins = :dm"); values[":dm"] = int(data["duration_mins"])
    if not updates:
        return _json({"error": "nothing to update"}, 400)
    kwargs = {
        "Key": {"PK": f"HH#{hh_id}", "SK": sk},
        "UpdateExpression": "SET " + ", ".join(updates),
        "ExpressionAttributeValues": values,
        "ConditionExpression": "attribute_exists(PK)",
    }
    if names:
        kwargs["ExpressionAttributeNames"] = names
    try:
        table.update_item(**kwargs)
    except _dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return _json({"error": "not found"}, 404)
    return _json({"ok": True})

def delete_nap(event):
    session, err = _require_session(event)
    if err: return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err: return mem_err
    sk = event.get("pathParameters", {}).get("sk", "")
    table.delete_item(Key={"PK": f"HH#{hh_id}", "SK": sk})
    return _json({"ok": True})

def post_settings(event):
    session, err = _require_session(event)
    if err: return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err: return mem_err
    data = _parse_body(event)
    current = _hh_settings(hh_id)
    if "countdown_secs" in data:
        current["countdown_secs"] = int(data["countdown_secs"])
    if "preset1_ml" in data:
        current["preset1_ml"] = max(10, min(500, int(data["preset1_ml"])))
    if "preset2_ml" in data:
        current["preset2_ml"] = max(10, min(500, int(data["preset2_ml"])))
    if "ss_timeout_min" in data:
        current["ss_timeout_min"] = int(data["ss_timeout_min"])
    table.put_item(Item={"PK": f"HH#{hh_id}", "SK": "SETTINGS", **current})
    return _json({"ok": True, "settings": current})

def post_reset_timer(event):
    session, err = _require_session(event)
    if err: return err
    hh_id = session.get("active_hh") or ""
    _, mem_err = _require_member(session, hh_id)
    if mem_err: return mem_err
    _put_hh_timer(hh_id, 0.0, "", 0, False)
    return _json({"ok": True})

# ── Associated Domains (AASA) ────────────────────────────────────────────────

def apple_app_site_association(event):
    """Serve apple-app-site-association for webcredentials (passkey) RP association."""
    team_id = os.environ.get("APPLE_TEAM_ID", "TV6FL9FHCE")
    bundle_id = os.environ.get("APPLE_BUNDLE_ID", "com.ashokteja.formulahelper.dev")
    body = json.dumps({"webcredentials": {"apps": [f"{team_id}.{bundle_id}"]}})
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json", "Cache-Control": "public, max-age=3600"},
        "body": body,
    }

# ── Router ───────────────────────────────────────────────────────────────────

PUBLIC_ROUTES = [
    ("GET",    r"^/\.well-known/apple-app-site-association$", apple_app_site_association),
    ("GET",    r"^/apple-app-site-association$",              apple_app_site_association),
    ("GET",    r"^/api/auth/status$",             auth_status),
    ("POST",   r"^/api/auth/siwa$",               auth_siwa),
    ("POST",   r"^/api/auth/logout$",             auth_logout),
    ("GET",    r"^/api/invites/(?P<token>[^/]+)$", invite_preview),
]

# Register the dev-login bypass only on dev stages so it is not even reachable
# (not just guarded) in prod. The runtime check inside the handler is kept as a
# second layer of defense in case STAGE is ever misconfigured at deploy time.
if STAGE == "dev":
    PUBLIC_ROUTES.append(
        ("POST", r"^/api/auth/dev-login$", auth_dev_login)
    )

PROTECTED_ROUTES = [
    ("GET",    r"^/api/households$",              households_list),
    ("POST",   r"^/api/households$",              households_create),
    ("POST",   r"^/api/households/switch$",       households_switch),
    ("GET",    r"^/api/households/(?P<hh_id>[^/]+)/members$", household_members_list),
    ("PUT",    r"^/api/households/(?P<hh_id>[^/]+)/members/(?P<user_id>[^/]+)$", household_member_update),
    ("DELETE", r"^/api/households/(?P<hh_id>[^/]+)/members/(?P<user_id>[^/]+)$", household_member_remove),
    ("POST",   r"^/api/households/(?P<hh_id>[^/]+)/leave$",    household_leave),
    ("POST",   r"^/api/households/(?P<hh_id>[^/]+)/transfer$", household_transfer),
    ("DELETE", r"^/api/households/(?P<hh_id>[^/]+)$",          household_delete),
    ("POST",   r"^/api/invites$",                 invite_create),
    ("POST",   r"^/api/invites/(?P<token>[^/]+)/redeem$", invite_redeem),
    ("GET",    r"^/api/state$",                   get_state),
    ("POST",   r"^/api/start$",                   post_start_feeding),
    ("POST",   r"^/api/feedings$",                post_feeding),
    ("PUT",    r"^/api/feedings/(?P<sk>.+)$",     put_feeding),
    ("DELETE", r"^/api/feedings/(?P<sk>.+)$",     delete_feeding),
    ("POST",   r"^/api/diapers$",                 post_diaper),
    ("PUT",    r"^/api/diapers/(?P<sk>.+)$",      put_diaper),
    ("DELETE", r"^/api/diapers/(?P<sk>.+)$",      delete_diaper),
    ("POST",   r"^/api/naps$",                    post_nap),
    ("PUT",    r"^/api/naps/(?P<sk>.+)$",         put_nap),
    ("DELETE", r"^/api/naps/(?P<sk>.+)$",         delete_nap),
    ("POST",   r"^/api/settings$",                post_settings),
    ("POST",   r"^/api/reset-timer$",             post_reset_timer),
]

def _match_route(routes, method: str, path: str):
    for m, pattern, handler in routes:
        if m != method:
            continue
        match = re.match(pattern, path)
        if match:
            return handler, match.groupdict()
    return None, None

def lambda_handler(event, context):
    http = event.get("requestContext", {}).get("http", {}) or {}
    method = http.get("method", "").upper()
    path = event.get("rawPath", "")

    # Inject path params from regex capture
    def dispatch(handler, params):
        event["pathParameters"] = {**(event.get("pathParameters") or {}), **params}
        try:
            return handler(event)
        except Exception as e:
            import traceback
            traceback.print_exc()
            return _json({"error": str(e)}, 500)

    handler, params = _match_route(PUBLIC_ROUTES, method, path)
    if handler:
        return dispatch(handler, params)

    handler, params = _match_route(PROTECTED_ROUTES, method, path)
    if handler:
        # Session check is handled inside each protected handler via _require_session.
        return dispatch(handler, params)

    return _json({"error": f"Unknown route: {method} {path}"}, 404)
