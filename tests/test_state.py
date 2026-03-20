"""Tests for GET /api/state — timer state, log entries, settings."""

import time
import json
import pytest
from decimal import Decimal
from tests.conftest import make_event, parse_response


class TestGetState:
    def test_empty_state(self, handler):
        """Fresh app returns sensible defaults."""
        event = make_event("GET /api/state")
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["mix_log"] == []
        assert body["mixed_at_str"] == ""
        assert body["mixed_ml"] == 0
        assert body["expired"] == False
        assert body["remaining_secs"] == 0
        assert "settings" in body
        assert "combos" in body
        assert body["powder_per_60"] == 8.3

    def test_state_with_active_timer(self, handler, table):
        """Returns correct remaining_secs when timer is active."""
        table.put_item(Item={
            "PK": "STATE", "SK": "TIMER",
            "countdown_end": Decimal(str(time.time() + 600)),
            "mixed_at_str": "10:00 AM",
            "mixed_ml": 90,
            "ntfy_sent": False,
        })

        event = make_event("GET /api/state")
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["mixed_at_str"] == "10:00 AM"
        assert body["mixed_ml"] == 90
        assert body["expired"] == False
        assert body["remaining_secs"] > 500

    def test_state_with_expired_timer(self, handler, table):
        """Returns expired=True when timer has passed."""
        table.put_item(Item={
            "PK": "STATE", "SK": "TIMER",
            "countdown_end": Decimal(str(time.time() - 60)),
            "mixed_at_str": "09:00 AM",
            "mixed_ml": 60,
            "ntfy_sent": True,
        })

        event = make_event("GET /api/state")
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["expired"] == True
        assert body["remaining_secs"] == 0

    def test_state_returns_log_entries(self, handler, table):
        """Log entries are returned in sorted order."""
        table.put_item(Item={
            "PK": "LOG", "SK": "2026-03-19#100.000",
            "text": "90ml @ 10:00 AM", "ml": 90, "date": "2026-03-19 10:00 AM",
            "leftover": "", "created_by": "Ashok",
        })
        table.put_item(Item={
            "PK": "LOG", "SK": "2026-03-19#200.000",
            "text": "60ml @ 02:00 PM", "ml": 60, "date": "2026-03-19 02:00 PM",
            "leftover": "20ml", "created_by": "Anu",
        })

        event = make_event("GET /api/state")
        status, body = parse_response(handler.lambda_handler(event, None))

        assert len(body["mix_log"]) == 2
        assert body["mix_log"][0]["ml"] == 90
        assert body["mix_log"][0]["created_by"] == "Ashok"
        assert body["mix_log"][1]["ml"] == 60
        assert body["mix_log"][1]["created_by"] == "Anu"
        assert body["mix_log"][1]["leftover"] == "20ml"

    def test_state_returns_settings(self, handler, table):
        """Custom settings are returned."""
        table.put_item(Item={
            "PK": "STATE", "SK": "SETTINGS",
            "countdown_secs": 1800, "ss_timeout_min": 5,
        })

        event = make_event("GET /api/state")
        status, body = parse_response(handler.lambda_handler(event, None))

        assert body["settings"]["countdown_secs"] == 1800
        assert body["settings"]["ss_timeout_min"] == 5

    def test_state_returns_combos(self, handler):
        """Combos list has 4 entries (60, 80, 90, 100)."""
        event = make_event("GET /api/state")
        status, body = parse_response(handler.lambda_handler(event, None))

        assert len(body["combos"]) == 4
        assert body["combos"][0][0] == 60
        assert body["combos"][3][0] == 100
