"""Tests for log CRUD — PUT /api/log/{sk}, DELETE /api/log/{sk}."""

import time
import json
import pytest
from decimal import Decimal
from tests.conftest import make_event, parse_response


class TestEditLog:
    def _create_entry(self, handler, ml=90):
        event = make_event("POST /api/start", body={"ml": ml})
        _, body = parse_response(handler.lambda_handler(event, None))
        return body["sk"]

    def test_edit_text(self, handler):
        """Edit the text field of a log entry."""
        sk = self._create_entry(handler)

        event = make_event("PUT /api/log/{sk}",
                          body={"text": "edited text"},
                          path_params={"sk": sk})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["ok"] == True

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert state["mix_log"][0]["text"] == "edited text"

    def test_edit_leftover(self, handler):
        """Edit the leftover field."""
        sk = self._create_entry(handler)

        event = make_event("PUT /api/log/{sk}",
                          body={"leftover": "20ml"},
                          path_params={"sk": sk})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert state["mix_log"][0]["leftover"] == "20ml"

    def test_edit_ml(self, handler):
        """Edit the ml value."""
        sk = self._create_entry(handler, ml=60)

        event = make_event("PUT /api/log/{sk}",
                          body={"ml": 90},
                          path_params={"sk": sk})
        handler.lambda_handler(event, None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert state["mix_log"][0]["ml"] == 90

    def test_edit_date(self, handler):
        """Edit the date field."""
        sk = self._create_entry(handler)

        event = make_event("PUT /api/log/{sk}",
                          body={"date": "2026-03-19 03:00 PM"},
                          path_params={"sk": sk})
        handler.lambda_handler(event, None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert state["mix_log"][0]["date"] == "2026-03-19 03:00 PM"

    def test_edit_multiple_fields(self, handler):
        """Edit ml, text, and leftover in one call."""
        sk = self._create_entry(handler)

        event = make_event("PUT /api/log/{sk}",
                          body={"ml": 120, "text": "120ml @ 04:00 PM", "leftover": "10ml"},
                          path_params={"sk": sk})
        handler.lambda_handler(event, None)

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        entry = state["mix_log"][0]
        assert entry["ml"] == 120
        assert entry["text"] == "120ml @ 04:00 PM"
        assert entry["leftover"] == "10ml"

    def test_edit_nonexistent_entry(self, handler):
        """Editing a non-existent SK returns 404."""
        event = make_event("PUT /api/log/{sk}",
                          body={"text": "nope"},
                          path_params={"sk": "fake-sk"})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 404
        assert body["ok"] == False

    def test_edit_no_fields(self, handler):
        """Edit with empty body returns 400."""
        sk = self._create_entry(handler)

        event = make_event("PUT /api/log/{sk}",
                          body={},
                          path_params={"sk": sk})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 400

    def test_edit_missing_sk(self, handler):
        """Edit with no SK returns 400."""
        event = make_event("PUT /api/log/{sk}",
                          body={"text": "test"},
                          path_params={"sk": ""})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 400


class TestDeleteLog:
    def _create_entries(self, handler, count=3):
        sks = []
        for i in range(count):
            event = make_event("POST /api/start", body={"ml": 60 + i * 30})
            _, body = parse_response(handler.lambda_handler(event, None))
            sks.append(body["sk"])
        return sks

    def test_delete_entry(self, handler):
        """Delete removes the entry."""
        sks = self._create_entries(handler, 2)

        event = make_event("DELETE /api/log/{sk}", path_params={"sk": sks[0]})
        status, body = parse_response(handler.lambda_handler(event, None))

        assert status == 200
        assert body["ok"] == True

        state_event = make_event("GET /api/state")
        _, state = parse_response(handler.lambda_handler(state_event, None))
        assert len(state["mix_log"]) == 1

    def test_delete_latest_restores_previous_timer(self, handler, table):
        """Deleting the latest entry restores the previous entry's timer state."""
        sks = self._create_entries(handler, 2)

        # Get the first entry's timer state
        state_event = make_event("GET /api/state")
        _, state_before = parse_response(handler.lambda_handler(state_event, None))
        first_entry = state_before["mix_log"][0]

        # Delete the latest (second) entry
        event = make_event("DELETE /api/log/{sk}", path_params={"sk": sks[1]})
        handler.lambda_handler(event, None)

        # Timer should reflect the first entry
        timer = handler._get_timer_state()
        assert timer["mixed_ml"] == first_entry["ml"]

    def test_delete_all_resets_timer(self, handler):
        """Deleting the last entry resets the timer."""
        sks = self._create_entries(handler, 1)

        event = make_event("DELETE /api/log/{sk}", path_params={"sk": sks[0]})
        handler.lambda_handler(event, None)

        timer = handler._get_timer_state()
        assert timer["mixed_at_str"] == ""
        assert timer["countdown_end"] == 0.0

    def test_delete_non_latest_doesnt_change_timer(self, handler):
        """Deleting an older entry doesn't affect the timer."""
        sks = self._create_entries(handler, 3)

        timer_before = handler._get_timer_state()

        event = make_event("DELETE /api/log/{sk}", path_params={"sk": sks[0]})
        handler.lambda_handler(event, None)

        timer_after = handler._get_timer_state()
        assert timer_after["mixed_at_str"] == timer_before["mixed_at_str"]

    def test_delete_missing_sk(self, handler):
        """Delete with no SK returns 400."""
        event = make_event("DELETE /api/log/{sk}", path_params={"sk": ""})
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 400
