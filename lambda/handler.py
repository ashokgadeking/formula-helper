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

import webauthn
from webauthn.helpers import bytes_to_base64url, base64url_to_bytes
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

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

def _require_member(session: dict, hh_id: str):
    """Verify session.user_id is a member of hh_id. Returns (member_item, error_response)."""
    item = table.get_item(Key={"PK": f"HH#{hh_id}", "SK": f"MEMBER#{session['user_id']}"}).get("Item")
    if not item:
        return None, _json({"error": "Forbidden"}, 403)
    return _decimal_to_native(item), None

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

def _put_credential(cred_id_b64: str, user_id: str, public_key: bytes, sign_count: int, label: str = ""):
    table.put_item(Item={
        "PK": f"CRED#{cred_id_b64}",
        "SK": "CRED",
        "credential_id": cred_id_b64,
        "user_id": user_id,
        "public_key": bytes_to_base64url(public_key),
        "sign_count": sign_count,
        "label": label,
        "created_at": _iso_now(),
    })

def _get_credential(cred_id_b64: str) -> dict | None:
    item = table.get_item(Key={"PK": f"CRED#{cred_id_b64}", "SK": "CRED"}).get("Item")
    return _decimal_to_native(item) if item else None

def _update_sign_count(cred_id_b64: str, new_count: int):
    table.update_item(
        Key={"PK": f"CRED#{cred_id_b64}", "SK": "CRED"},
        UpdateExpression="SET sign_count = :c",
        ExpressionAttributeValues={":c": new_count},
    )

def _list_credentials_for_user(user_id: str) -> list[dict]:
    # Scan-like: in dev volume this is fine. At scale add a GSI on user_id.
    resp = table.scan(
        FilterExpression=Key("PK").begins_with("CRED#"),
    )
    return [_decimal_to_native(i) for i in resp.get("Items", []) if i.get("user_id") == user_id]

# ── Households / memberships ─────────────────────────────────────────────────

def _create_household(name: str, owner_uid: str) -> str:
    hh_id = _new_id("h_")
    now = _iso_now()
    table.put_item(Item={
        "PK": f"HH#{hh_id}",
        "SK": "META",
        "hh_id": hh_id,
        "name": name,
        "owner_uid": owner_uid,
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

def auth_register_start(event):
    """
    Begin signup. Two flavors:
      - With invite_token: SIWA required; will join existing household.
      - Without invite_token: SIWA required; will create a new household.
    Body: { siwa_id_token: str, invite_token?: str, household_name?: str, user_name: str }
    Returns passkey registration options + challenge_id.
    """
    data = _parse_body(event)
    siwa_token = data.get("siwa_id_token") or ""
    user_name = (data.get("user_name") or "").strip()
    invite_token = data.get("invite_token") or ""
    household_name = (data.get("household_name") or "").strip()

    if not siwa_token or not user_name:
        return _json({"error": "siwa_id_token and user_name required"}, 400)

    try:
        claims = _verify_siwa(siwa_token)
    except Exception as e:
        return _json({"error": f"SIWA verification failed: {e}"}, 400)

    apple_sub = claims["sub"]
    email = claims.get("email")

    # Reject if this apple_sub already has a user (use login instead)
    if _user_id_for_apple_sub(apple_sub):
        return _json({"error": "Account already exists for this Apple ID. Sign in instead."}, 409)

    # Invite path: validate invite up front so we fail fast
    invite = None
    if invite_token:
        invite = _get_invite(invite_token)
        if not invite or invite.get("used_at") or invite.get("expires", 0) < _now():
            return _json({"error": "Invite is invalid or expired"}, 400)
    elif not household_name:
        return _json({"error": "household_name required when no invite_token"}, 400)

    # Pre-mint user_id so we can bind the future credential to it
    user_id = _new_id("u_")

    options = webauthn.generate_registration_options(
        rp_id=RP_ID,
        rp_name=RP_NAME,
        user_id=user_id.encode(),
        user_name=user_name,
        user_display_name=user_name,
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.PREFERRED,
            user_verification=UserVerificationRequirement.PREFERRED,
        ),
    )

    challenge_b64 = bytes_to_base64url(options.challenge)
    cid = _put_challenge(
        challenge_b64,
        purpose="register",
        extra={
            "user_id": user_id,
            "apple_sub": apple_sub,
            "email": email or "",
            "user_name": user_name,
            "invite_token": invite_token,
            "household_name": household_name,
        },
    )

    return _json({
        "challenge_id": cid,
        "options": json.loads(webauthn.options_to_json(options)),
    })

def auth_register_finish(event):
    """Body: { challenge_id, credential: <WebAuthn attestation response> }"""
    data = _parse_body(event)
    cid = data.get("challenge_id") or ""
    credential = data.get("credential") or {}

    ctx = _pop_challenge(cid, "register")
    if not ctx:
        return _json({"error": "Challenge expired or invalid"}, 400)

    try:
        verification = webauthn.verify_registration_response(
            credential=credential,
            expected_challenge=base64url_to_bytes(ctx["challenge"]),
            expected_rp_id=RP_ID,
            expected_origin=RP_ORIGIN,
        )
    except Exception as e:
        return _json({"error": str(e)}, 400)

    user_id = ctx["user_id"]
    apple_sub = ctx["apple_sub"]
    user_name = ctx["user_name"]
    invite_token = ctx.get("invite_token") or ""
    household_name = ctx.get("household_name") or ""

    # Create USER
    _put_user(user_id, apple_sub=apple_sub, name=user_name, email=ctx.get("email"))

    # Store credential
    cred_id_b64 = bytes_to_base64url(verification.credential_id)
    _put_credential(
        cred_id_b64,
        user_id=user_id,
        public_key=verification.credential_public_key,
        sign_count=verification.sign_count,
        label="primary",
    )

    # Household: invite → join, else create
    if invite_token:
        invite = _consume_invite(invite_token)
        if not invite:
            return _json({"error": "Invite was consumed or expired"}, 400)
        hh_id = invite["hh_id"]
        hh_name = invite.get("hh_name", "")
        _add_membership(hh_id, user_id, role="member", hh_name=hh_name)
    else:
        hh_id = _create_household(household_name, owner_uid=user_id)

    token, _ = _create_session(user_id, active_hh=hh_id)
    return _json(
        {"ok": True, "user_id": user_id, "active_hh": hh_id},
        cookies=[_session_cookie(token)],
    )

def auth_login_options(event):
    options = webauthn.generate_authentication_options(
        rp_id=RP_ID,
        user_verification=UserVerificationRequirement.PREFERRED,
    )
    challenge_b64 = bytes_to_base64url(options.challenge)
    cid = _put_challenge(challenge_b64, purpose="login")
    return _json({
        "challenge_id": cid,
        "options": json.loads(webauthn.options_to_json(options)),
    })

def auth_login_verify(event):
    data = _parse_body(event)
    cid = data.get("challenge_id") or ""
    credential = data.get("credential") or {}

    ctx = _pop_challenge(cid, "login")
    if not ctx:
        return _json({"error": "Challenge expired or invalid"}, 400)

    cred_id_b64 = credential.get("id", "")
    cred = _get_credential(cred_id_b64)
    if not cred:
        return _json({"error": "Unknown credential"}, 400)

    try:
        verification = webauthn.verify_authentication_response(
            credential=credential,
            expected_challenge=base64url_to_bytes(ctx["challenge"]),
            expected_rp_id=RP_ID,
            expected_origin=RP_ORIGIN,
            credential_public_key=base64url_to_bytes(cred["public_key"]),
            credential_current_sign_count=int(cred.get("sign_count", 0)),
        )
    except Exception as e:
        return _json({"error": str(e)}, 400)

    _update_sign_count(cred_id_b64, verification.new_sign_count)

    user_id = cred["user_id"]
    # Pick active_hh: first membership (client can switch via /households/switch)
    memberships = _list_memberships(user_id)
    active_hh = memberships[0]["hh_id"] if memberships else None

    token, _ = _create_session(user_id, active_hh=active_hh)
    return _json(
        {"ok": True, "user_id": user_id, "active_hh": active_hh},
        cookies=[_session_cookie(token)],
    )

def auth_recover_start(event):
    """SIWA-based recovery. Body: { siwa_id_token }. Returns registration options to add a new passkey to the existing user."""
    data = _parse_body(event)
    siwa_token = data.get("siwa_id_token") or ""
    if not siwa_token:
        return _json({"error": "siwa_id_token required"}, 400)

    try:
        claims = _verify_siwa(siwa_token)
    except Exception as e:
        return _json({"error": f"SIWA verification failed: {e}"}, 400)

    user_id = _user_id_for_apple_sub(claims["sub"])
    if not user_id:
        return _json({"error": "No account associated with this Apple ID"}, 404)

    user = _get_user(user_id) or {}
    options = webauthn.generate_registration_options(
        rp_id=RP_ID,
        rp_name=RP_NAME,
        user_id=user_id.encode(),
        user_name=user.get("name", "user"),
        user_display_name=user.get("name", "user"),
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.PREFERRED,
            user_verification=UserVerificationRequirement.PREFERRED,
        ),
    )
    challenge_b64 = bytes_to_base64url(options.challenge)
    cid = _put_challenge(challenge_b64, purpose="recover", extra={"user_id": user_id})

    return _json({
        "challenge_id": cid,
        "options": json.loads(webauthn.options_to_json(options)),
    })

def auth_recover_finish(event):
    """Body: { challenge_id, credential }. Attaches a new passkey to the existing user."""
    data = _parse_body(event)
    cid = data.get("challenge_id") or ""
    credential = data.get("credential") or {}

    ctx = _pop_challenge(cid, "recover")
    if not ctx:
        return _json({"error": "Challenge expired or invalid"}, 400)

    try:
        verification = webauthn.verify_registration_response(
            credential=credential,
            expected_challenge=base64url_to_bytes(ctx["challenge"]),
            expected_rp_id=RP_ID,
            expected_origin=RP_ORIGIN,
        )
    except Exception as e:
        return _json({"error": str(e)}, 400)

    user_id = ctx["user_id"]
    cred_id_b64 = bytes_to_base64url(verification.credential_id)
    _put_credential(
        cred_id_b64,
        user_id=user_id,
        public_key=verification.credential_public_key,
        sign_count=verification.sign_count,
        label="recovered",
    )

    memberships = _list_memberships(user_id)
    active_hh = memberships[0]["hh_id"] if memberships else None
    token, _ = _create_session(user_id, active_hh=active_hh)
    return _json(
        {"ok": True, "user_id": user_id, "active_hh": active_hh},
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
    return _json({
        "active_hh": session.get("active_hh", ""),
        "households": [
            {"hh_id": m["hh_id"], "name": m.get("hh_name", ""), "role": m.get("role", "")}
            for m in memberships
        ],
    })

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
    _, mem_err = _require_member(session, hh_id)
    if mem_err:
        return mem_err
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
    ("POST",   r"^/api/auth/register/start$",     auth_register_start),
    ("POST",   r"^/api/auth/register/finish$",    auth_register_finish),
    ("POST",   r"^/api/auth/login/options$",      auth_login_options),
    ("POST",   r"^/api/auth/login/verify$",       auth_login_verify),
    ("POST",   r"^/api/auth/recover/start$",      auth_recover_start),
    ("POST",   r"^/api/auth/recover/finish$",     auth_recover_finish),
    ("POST",   r"^/api/auth/logout$",             auth_logout),
    ("GET",    r"^/api/invites/(?P<token>[^/]+)$", invite_preview),
]

PROTECTED_ROUTES = [
    ("GET",    r"^/api/households$",              households_list),
    ("POST",   r"^/api/households$",              households_create),
    ("POST",   r"^/api/households/switch$",       households_switch),
    ("GET",    r"^/api/households/(?P<hh_id>[^/]+)/members$", household_members_list),
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
