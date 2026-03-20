"""Tests for POST /api/settings and POST /api/reset-timer."""

import time
import json
import pytest
from tests.conftest import make_event, parse_response


class TestSettings:
    def test_update_countdown_secs(self, handler):
        """Update countdown timer duration."""
        event = make_event("POST /api/settings", body={"countdown_secs": 1800})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["ok"] == True
        assert body["settings"]["countdown_secs"] == 1800

    def test_update_ss_timeout(self, handler):
        """Update screensaver timeout."""
        event = make_event("POST /api/settings", body={"ss_timeout_min": 5})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["settings"]["ss_timeout_min"] == 5

    def test_update_both(self, handler):
        """Update both settings at once."""
        event = make_event("POST /api/settings",
                          body={"countdown_secs": 2400, "ss_timeout_min": 10})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert body["settings"]["countdown_secs"] == 2400
        assert body["settings"]["ss_timeout_min"] == 10

    def test_partial_update_preserves_other(self, handler):
        """Updating one setting preserves the other."""
        # Set both first
        handler.lambda_handler(
            make_event("POST /api/settings",
                      body={"countdown_secs": 1800, "ss_timeout_min": 5}), None)

        # Update only one
        handler.lambda_handler(
            make_event("POST /api/settings",
                      body={"countdown_secs": 2400}), None)

        settings = handler._get_settings()
        assert settings["countdown_secs"] == 2400
        assert settings["ss_timeout_min"] == 5

    def test_settings_persist_in_state(self, handler):
        """Settings are reflected in GET /api/state."""
        handler.lambda_handler(
            make_event("POST /api/settings",
                      body={"countdown_secs": 1200}), None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert state["settings"]["countdown_secs"] == 1200


class TestResetTimer:
    def test_reset_clears_timer(self, handler):
        """Reset timer zeros out all timer fields."""
        # Start a timer first
        handler.lambda_handler(
            make_event("POST /api/start", body={"ml": 90}), None)

        # Reset
        event = make_event("POST /api/reset-timer")
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["ok"] == True

        timer = handler._get_timer_state()
        assert timer["countdown_end"] == 0.0
        assert timer["mixed_at_str"] == ""
        assert timer["mixed_ml"] == 0

    def test_reset_shows_no_bottle(self, handler):
        """After reset, state shows no active bottle."""
        handler.lambda_handler(
            make_event("POST /api/start", body={"ml": 60}), None)
        handler.lambda_handler(
            make_event("POST /api/reset-timer"), None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert state["mixed_at_str"] == ""
        assert state["expired"] == False

    def test_reset_doesnt_delete_log(self, handler):
        """Reset timer doesn't remove log entries."""
        handler.lambda_handler(
            make_event("POST /api/start", body={"ml": 90}), None)
        handler.lambda_handler(
            make_event("POST /api/reset-timer"), None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert len(state["mix_log"]) == 1
