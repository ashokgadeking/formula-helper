"""Tests for POST /api/weight — uploading weight log."""

import pytest
from tests.conftest import make_event, parse_response


class TestPostWeight:
    def test_upload_weight_entries(self, handler):
        """Upload weight entries stores them and returns count."""
        entries = [
            {"date": "2026-03-01", "lbs": 14.5},
            {"date": "2026-03-15", "lbs": 15.2},
        ]
        event = make_event("POST /api/weight", body={"entries": entries})
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 200
        assert body["ok"] == True
        assert body["count"] == 2

    def test_weight_appears_in_state(self, handler):
        """After upload, weight_log appears in GET /api/state."""
        entries = [{"date": "2026-03-01", "lbs": 14.5}]
        handler.lambda_handler(make_event("POST /api/weight", body={"entries": entries}), None)

        _, state = parse_response(handler.lambda_handler(make_event("GET /api/state"), None))
        assert "weight_log" in state
        assert len(state["weight_log"]) == 1
        assert state["weight_log"][0]["lbs"] == 14.5

    def test_upload_replaces_previous(self, handler):
        """Uploading again replaces previous weight data."""
        handler.lambda_handler(make_event("POST /api/weight", body={"entries": [
            {"date": "2026-02-01", "lbs": 13.0}
        ]}), None)
        handler.lambda_handler(make_event("POST /api/weight", body={"entries": [
            {"date": "2026-03-01", "lbs": 14.5},
            {"date": "2026-03-15", "lbs": 15.2},
        ]}), None)

        _, state = parse_response(handler.lambda_handler(make_event("GET /api/state"), None))
        assert len(state["weight_log"]) == 2
        assert state["weight_log"][0]["date"] == "2026-03-01"

    def test_upload_sorted_by_date(self, handler):
        """Entries are returned sorted by date."""
        entries = [
            {"date": "2026-03-15", "lbs": 15.2},
            {"date": "2026-01-01", "lbs": 10.5},
            {"date": "2026-02-01", "lbs": 13.0},
        ]
        handler.lambda_handler(make_event("POST /api/weight", body={"entries": entries}), None)
        _, state = parse_response(handler.lambda_handler(make_event("GET /api/state"), None))
        dates = [e["date"] for e in state["weight_log"]]
        assert dates == sorted(dates)

    def test_state_weight_log_empty_when_none(self, handler):
        """weight_log is empty list when no data uploaded."""
        _, state = parse_response(handler.lambda_handler(make_event("GET /api/state"), None))
        assert state["weight_log"] == []

    def test_upload_invalid_entries_skipped(self, handler):
        """Invalid entries are skipped, valid ones are stored."""
        entries = [
            {"date": "2026-03-01", "lbs": 14.5},
            {"date": "bad-date", "lbs": "not-a-number"},
            {},
        ]
        event = make_event("POST /api/weight", body={"entries": entries})
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 200
        assert body["count"] == 1

    def test_upload_not_list_returns_400(self, handler):
        """Non-list entries returns 400."""
        event = make_event("POST /api/weight", body={"entries": "bad"})
        status, body = parse_response(handler.lambda_handler(event, None))
        assert status == 400
