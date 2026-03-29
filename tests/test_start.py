"""Tests for POST /api/start — starting a new bottle timer."""

import time
import json
import pytest
from decimal import Decimal
from tests.conftest import make_event, parse_response


class TestPostStart:
    def test_start_creates_log_entry(self, handler):
        """Starting a timer creates a log entry."""
        event = make_event("POST /api/start", body={"ml": 90})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["ok"] == True
        assert "sk" in body

        # Verify log entry exists
        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert len(state["mix_log"]) == 1
        assert state["mix_log"][0]["ml"] == 90

    def test_start_sets_timer(self, handler, table):
        """Starting a timer updates the timer state."""
        table.put_item(Item={
            "PK": "STATE", "SK": "SETTINGS",
            "countdown_secs": 1800, "ss_timeout_min": 2,
        })

        event = make_event("POST /api/start", body={"ml": 60})
        handler.lambda_handler(event, None)

        timer = handler._get_timer_state()
        assert timer["mixed_ml"] == 60
        assert timer["mixed_at_str"] != ""
        assert timer["ntfy_sent"] == False
        assert timer["countdown_end"] > time.time()
        assert timer["countdown_end"] < time.time() + 1801

    def test_start_defaults_to_90ml(self, handler):
        """No ml parameter defaults to 90."""
        event = make_event("POST /api/start", body={})
        handler.lambda_handler(event, None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert state["mix_log"][0]["ml"] == 90

    def test_start_text_format(self, handler):
        """Log entry text follows 'NNml @ HH:MM AM/PM' format."""
        event = make_event("POST /api/start", body={"ml": 120})
        handler.lambda_handler(event, None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        text = state["mix_log"][0]["text"]
        assert text.startswith("120ml @ ")
        assert ("AM" in text or "PM" in text)

    def test_start_multiple_entries(self, handler):
        """Multiple starts create multiple log entries in order."""
        for ml in [60, 90, 120]:
            event = make_event("POST /api/start", body={"ml": ml})
            handler.lambda_handler(event, None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert len(state["mix_log"]) == 3
        # Timer reflects last entry
        assert state["mixed_ml"] == 120

    def test_start_tags_pi_user(self, handler):
        """Entries from Pi API key are tagged as 'Pi'."""
        event = make_event("POST /api/start",
                          body={"ml": 90},
                          headers={"x-api-key": "test-pi-key"})
        handler.lambda_handler(event, None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert state["mix_log"][0]["created_by"] == "Pi"

    def test_start_resets_ntfy_sent(self, handler, table):
        """Starting a new timer resets ntfy_sent to False."""
        table.put_item(Item={
            "PK": "STATE", "SK": "TIMER",
            "countdown_end": Decimal(str(time.time() - 100)),
            "mixed_at_str": "old", "mixed_ml": 60, "ntfy_sent": True,
        })

        event = make_event("POST /api/start", body={"ml": 90})
        handler.lambda_handler(event, None)

        timer = handler._get_timer_state()
        assert timer["ntfy_sent"] == False
