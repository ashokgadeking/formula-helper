"""Tests for helper functions — JSON response, body parsing, conversions."""

import json
import base64
import pytest
from decimal import Decimal


class TestJsonResponse:
    def test_basic_response(self, handler):
        resp = handler._json_response({"ok": True})
        assert resp["statusCode"] == 200
        assert json.loads(resp["body"]) == {"ok": True}
        assert "no-store" in resp["headers"]["Cache-Control"]

    def test_custom_status(self, handler):
        resp = handler._json_response({"error": "bad"}, 400)
        assert resp["statusCode"] == 400

    def test_decimal_serialization(self, handler):
        resp = handler._json_response({"val": Decimal("3.14")})
        body = json.loads(resp["body"])
        assert float(body["val"]) == 3.14


class TestParseBody:
    def test_json_body(self, handler):
        event = {"body": '{"ml": 90}'}
        assert handler._parse_body(event) == {"ml": 90}

    def test_base64_body(self, handler):
        raw = base64.b64encode(b'{"ml": 60}').decode()
        event = {"body": raw, "isBase64Encoded": True}
        assert handler._parse_body(event) == {"ml": 60}

    def test_empty_body(self, handler):
        assert handler._parse_body({"body": ""}) == {}
        assert handler._parse_body({}) == {}


class TestDecimalToNative:
    def test_integer_decimal(self, handler):
        assert handler._decimal_to_native(Decimal("42")) == 42

    def test_float_decimal(self, handler):
        assert handler._decimal_to_native(Decimal("3.14")) == 3.14

    def test_nested_dict(self, handler):
        result = handler._decimal_to_native({
            "a": Decimal("1"),
            "b": {"c": Decimal("2.5")},
            "d": [Decimal("3"), "text"],
        })
        assert result == {"a": 1, "b": {"c": 2.5}, "d": [3, "text"]}

    def test_passthrough(self, handler):
        assert handler._decimal_to_native("hello") == "hello"
        assert handler._decimal_to_native(42) == 42
        assert handler._decimal_to_native(None) is None


class TestLogEntryToApi:
    def test_converts_all_fields(self, handler):
        item = {
            "PK": "LOG", "SK": "2026-03-19#100.000",
            "text": "90ml @ 10:00 AM",
            "leftover": "20ml",
            "ml": Decimal("90"),
            "date": "2026-03-19 10:00 AM",
            "created_by": "Ashok",
        }
        result = handler._log_entry_to_api(handler._decimal_to_native(item))
        assert result == {
            "sk": "2026-03-19#100.000",
            "text": "90ml @ 10:00 AM",
            "leftover": "20ml",
            "ml": 90,
            "date": "2026-03-19 10:00 AM",
            "created_by": "Ashok",
        }

    def test_missing_fields_default(self, handler):
        item = {"PK": "LOG", "SK": "2026-03-19#100.000"}
        result = handler._log_entry_to_api(item)
        assert result["text"] == ""
        assert result["leftover"] == ""
        assert result["ml"] == 0
        assert result["created_by"] == ""


class TestSessionCookie:
    def test_cookie_format(self, handler):
        cookie = handler._session_cookie("tok123", 3600)
        assert "session=tok123" in cookie
        assert "Path=/" in cookie
        assert "Max-Age=3600" in cookie
        assert "Secure" in cookie
        assert "HttpOnly" in cookie
        assert "SameSite=Lax" in cookie
