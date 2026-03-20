"""Tests for expiry notifications and weekly summary."""

import time
import json
import pytest
from decimal import Decimal
from unittest.mock import patch, MagicMock
from tests.conftest import make_event, parse_response


class TestExpiryNotification:
    def test_sends_ntfy_on_expiry(self, handler, table):
        """Notification is sent when timer expires."""
        table.put_item(Item={
            "PK": "STATE", "SK": "TIMER",
            "countdown_end": Decimal(str(time.time() - 10)),
            "mixed_at_str": "10:00 AM",
            "mixed_ml": 90,
            "ntfy_sent": False,
        })

        with patch.object(handler, 'urllib') as mock_urllib:
            mock_resp = MagicMock()
            mock_resp.status = 200
            mock_urllib.request.urlopen.return_value = mock_resp

            event = make_event("GET /api/state")
            status, body = parse_response(handler.lambda_handler(event, None))

            assert body["ntfy_sent"] == True

    def test_no_duplicate_notification(self, handler, table):
        """Notification is not sent if ntfy_sent is already True."""
        table.put_item(Item={
            "PK": "STATE", "SK": "TIMER",
            "countdown_end": Decimal(str(time.time() - 10)),
            "mixed_at_str": "10:00 AM",
            "mixed_ml": 90,
            "ntfy_sent": True,
        })

        with patch.object(handler, 'urllib') as mock_urllib:
            event = make_event("GET /api/state")
            handler.lambda_handler(event, None)

            # urlopen should not be called for ntfy
            mock_urllib.request.urlopen.assert_not_called()

    def test_no_notification_when_not_expired(self, handler, table):
        """No notification when timer is still active."""
        table.put_item(Item={
            "PK": "STATE", "SK": "TIMER",
            "countdown_end": Decimal(str(time.time() + 3600)),
            "mixed_at_str": "10:00 AM",
            "mixed_ml": 90,
            "ntfy_sent": False,
        })

        with patch.object(handler, 'urllib') as mock_urllib:
            event = make_event("GET /api/state")
            status, body = parse_response(handler.lambda_handler(event, None))

            assert body["ntfy_sent"] == False

    def test_concurrent_expiry_check(self, handler, table):
        """Conditional update prevents race condition on notification send."""
        table.put_item(Item={
            "PK": "STATE", "SK": "TIMER",
            "countdown_end": Decimal(str(time.time() - 10)),
            "mixed_at_str": "10:00 AM",
            "mixed_ml": 90,
            "ntfy_sent": False,
        })

        # First call sends notification
        event = make_event("GET /api/state")
        _, body1 = parse_response(handler.lambda_handler(event, None))
        assert body1["ntfy_sent"] == True

        # Second call should not re-send
        _, body2 = parse_response(handler.lambda_handler(event, None))
        assert body2["ntfy_sent"] == True


class TestRestoreStateFromLog:
    def test_restore_from_latest(self, handler, table):
        """Restoring state from log picks up the latest entry."""
        table.put_item(Item={
            "PK": "LOG", "SK": "2026-03-19#100.000",
            "text": "90ml @ 10:00 AM", "ml": 90,
            "date": "2026-03-19 10:00 AM", "leftover": "", "created_by": "",
        })
        table.put_item(Item={
            "PK": "LOG", "SK": "2026-03-19#200.000",
            "text": "60ml @ 02:00 PM", "ml": 60,
            "date": "2026-03-19 02:00 PM", "leftover": "", "created_by": "",
        })

        handler._restore_state_from_log()

        timer = handler._get_timer_state()
        assert timer["mixed_ml"] == 60
        assert "02:00 PM" in timer["mixed_at_str"]

    def test_restore_empty_log(self, handler):
        """Restoring from empty log clears the timer."""
        handler._restore_state_from_log()

        timer = handler._get_timer_state()
        assert timer["countdown_end"] == 0.0
        assert timer["mixed_at_str"] == ""


class TestWeeklyInsights:
    def test_compute_weekly_insights(self, handler, table):
        """Weekly insights computes correct stats."""
        from datetime import datetime, timedelta

        # Use naive datetimes to match what _compute_weekly_insights parses
        now = datetime.now()

        # Add entries for this week
        for i in range(3):
            d = now - timedelta(hours=i * 4)
            table.put_item(Item={
                "PK": "LOG",
                "SK": f"{d.strftime('%Y-%m-%d')}#{d.timestamp():.3f}",
                "text": f"90ml @ {d.strftime('%I:%M %p')}",
                "ml": 90,
                "date": d.strftime("%Y-%m-%d %I:%M %p"),
                "leftover": "", "created_by": "",
            })

        entries = handler._get_all_log_entries()
        insights = handler._compute_weekly_insights(entries)

        assert insights["this_week_ml"] == 270
        assert insights["this_week_bottles"] == 3
