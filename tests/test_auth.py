"""Tests for authentication — sessions, API key, route protection."""

import time
import json
import pytest
from tests.conftest import make_event, parse_response


class TestAuthStatus:
    def test_no_creds_no_session(self, handler):
        """Fresh app — not authenticated, not registered."""
        event = make_event("GET /api/auth/status")
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["authenticated"] == False
        assert body["registered"] == False

    def test_with_valid_session(self, handler, table):
        """Valid session returns authenticated=True."""
        token = "test-token-123"
        table.put_item(Item={
            "PK": "AUTH", "SK": f"SESSION#{token}",
            "expires": int(time.time()) + 3600,
            "user_name": "Ashok", "cred_id": "",
        })

        event = make_event("GET /api/auth/status", cookies=[f"session={token}"])
        status, body = parse_response(handler.lambda_handler(event, None))

        assert body["authenticated"] == True
        assert body["user_name"] == "Ashok"

    def test_with_expired_session(self, handler, table):
        """Expired session returns authenticated=False."""
        token = "expired-token"
        table.put_item(Item={
            "PK": "AUTH", "SK": f"SESSION#{token}",
            "expires": int(time.time()) - 100,
            "user_name": "Ashok", "cred_id": "",
        })

        event = make_event("GET /api/auth/status", cookies=[f"session={token}"])
        status, body = parse_response(handler.lambda_handler(event, None))

        assert body["authenticated"] == False


class TestRouteProtection:
    def test_unprotected_when_no_creds(self, handler):
        """Routes are unprotected when no credentials are registered."""
        event = make_event("GET /api/state")
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 200

    def test_protected_when_creds_exist(self, handler, table):
        """Routes return 401 when credentials exist but no session."""
        table.put_item(Item={
            "PK": "AUTH", "SK": "CRED#test-cred",
            "credential_id": "test-cred",
            "public_key": "test-key",
            "sign_count": 0, "user_name": "Ashok",
        })

        event = make_event("GET /api/state")
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 401

    def test_pi_api_key_bypasses_auth(self, handler, table):
        """Pi API key grants access even when credentials exist."""
        table.put_item(Item={
            "PK": "AUTH", "SK": "CRED#test-cred",
            "credential_id": "test-cred",
            "public_key": "test-key",
            "sign_count": 0, "user_name": "Ashok",
        })

        event = make_event("GET /api/state", headers={"x-api-key": "test-pi-key"})
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 200

    def test_wrong_api_key_rejected(self, handler, table):
        """Wrong API key is rejected."""
        table.put_item(Item={
            "PK": "AUTH", "SK": "CRED#test-cred",
            "credential_id": "test-cred",
            "public_key": "test-key",
            "sign_count": 0, "user_name": "Ashok",
        })

        event = make_event("GET /api/state", headers={"x-api-key": "wrong-key"})
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 401

    def test_valid_session_grants_access(self, handler, table):
        """Valid session cookie grants access to protected routes."""
        table.put_item(Item={
            "PK": "AUTH", "SK": "CRED#test-cred",
            "credential_id": "test-cred",
            "public_key": "test-key",
            "sign_count": 0, "user_name": "Ashok",
        })

        token = "valid-token"
        table.put_item(Item={
            "PK": "AUTH", "SK": f"SESSION#{token}",
            "expires": int(time.time()) + 3600,
            "user_name": "Ashok", "cred_id": "",
        })

        event = make_event("GET /api/state", cookies=[f"session={token}"])
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 200

    def test_auth_routes_always_accessible(self, handler, table):
        """Auth status endpoint is accessible without session."""
        table.put_item(Item={
            "PK": "AUTH", "SK": "CRED#test-cred",
            "credential_id": "test-cred",
            "public_key": "test-key",
            "sign_count": 0, "user_name": "Ashok",
        })

        event = make_event("GET /api/auth/status")
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 200


class TestRegistrationRestriction:
    def test_register_open_when_no_creds(self, handler):
        """Registration options are accessible with no session when no creds exist yet."""
        event = make_event("POST /api/auth/register-options", body={"username": "Ashok"})
        status, _ = parse_response(handler.lambda_handler(event, None))
        assert status == 200

    def test_register_blocked_without_session_when_creds_exist(self, handler, table):
        """Registration is blocked without a session once any credential exists."""
        table.put_item(Item={
            "PK": "AUTH", "SK": "CRED#test-cred",
            "credential_id": "test-cred", "public_key": "test-key",
            "sign_count": 0, "user_name": "Ashok",
        })
        event = make_event("POST /api/auth/register-options", body={"username": "NewUser"})
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 401

    def test_register_allowed_with_valid_session_when_creds_exist(self, handler, table):
        """Registration is allowed with a valid session even after creds exist."""
        table.put_item(Item={
            "PK": "AUTH", "SK": "CRED#test-cred",
            "credential_id": "test-cred", "public_key": "test-key",
            "sign_count": 0, "user_name": "Ashok",
        })
        token = "valid-token"
        table.put_item(Item={
            "PK": "AUTH", "SK": f"SESSION#{token}",
            "expires": int(time.time()) + 86400,
            "user_name": "Ashok",
        })
        event = make_event("POST /api/auth/register-options",
                          body={"username": "Ashok"},
                          cookies=[f"session={token}"])
        status, _ = parse_response(handler.lambda_handler(event, None))
        assert status == 200


class TestUnknownRoute:
    def test_unknown_route_returns_404(self, handler):
        """Unknown route returns 404."""
        event = make_event("GET /api/nonexistent")
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 404
