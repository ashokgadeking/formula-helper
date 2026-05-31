#!/usr/bin/env python3
"""
One-time migration: seed DynamoDB from local JSON files.
Usage: AWS_PROFILE=citadel python3 migrate.py
"""

import json
import time
from datetime import datetime
from decimal import Decimal

import boto3

TABLE_NAME = "FormulaHelper"
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def migrate_log(log_file="mix_log.json"):
    """Migrate mix_log.json entries to DynamoDB."""
    try:
        with open(log_file) as f:
            entries = json.load(f)
    except FileNotFoundError:
        print(f"  {log_file} not found, skipping log migration")
        return 0

    count = 0
    with table.batch_writer() as batch:
        for i, e in enumerate(entries):
            if isinstance(e, str):
                # Legacy string entry
                sk = f"0000-00-00#{i:06d}"
                batch.put_item(Item={
                    "PK": "LOG",
                    "SK": sk,
                    "text": e,
                    "leftover": "",
                    "ml": 0,
                    "date": "",
                })
                count += 1
                continue

            date_str = e.get("date", "")
            if date_str:
                try:
                    dt = datetime.strptime(date_str, "%Y-%m-%d %I:%M %p")
                    ts = dt.timestamp()
                    day = dt.strftime("%Y-%m-%d")
                    # Add sub-index to guarantee uniqueness
                    sk = f"{day}#{ts:.3f}{i:03d}"
                except ValueError:
                    sk = f"0000-00-00#{i:06d}"
            else:
                sk = f"0000-00-00#{i:06d}"

            batch.put_item(Item={
                "PK": "LOG",
                "SK": sk,
                "text": e.get("text", ""),
                "leftover": e.get("leftover", ""),
                "ml": e.get("ml", 0),
                "date": date_str,
            })
            count += 1

    print(f"  Migrated {count} log entries")
    return count


def migrate_state(state_file="countdown_state.json"):
    """Migrate countdown_state.json to DynamoDB."""
    try:
        with open(state_file) as f:
            state = json.load(f)
    except FileNotFoundError:
        print(f"  {state_file} not found, writing default timer state")
        state = {}

    table.put_item(Item={
        "PK": "STATE",
        "SK": "TIMER",
        "countdown_end": Decimal(str(state.get("countdown_end", 0))),
        "mixed_at_str": state.get("mixed_at_str", ""),
        "mixed_ml": state.get("mixed_ml", 0),
        "ntfy_sent": state.get("ntfy_sent", False),
    })
    print(f"  Migrated timer state: {state.get('mixed_at_str', '(empty)')}")


def migrate_settings(settings_file="settings.json"):
    """Migrate settings.json to DynamoDB."""
    try:
        with open(settings_file) as f:
            settings = json.load(f)
    except FileNotFoundError:
        print(f"  {settings_file} not found, writing defaults")
        settings = {}

    table.put_item(Item={
        "PK": "STATE",
        "SK": "SETTINGS",
        "countdown_secs": settings.get("countdown_secs", 65 * 60),
        "ss_timeout_min": settings.get("ss_timeout_min", 2),
    })
    print(f"  Migrated settings: countdown={settings.get('countdown_secs', 3900)}s")


def main():
    print(f"Migrating to DynamoDB table: {TABLE_NAME}")
    print()

    print("1. Log entries:")
    migrate_log()
    print()

    print("2. Timer state:")
    migrate_state()
    print()

    print("3. Settings:")
    migrate_settings()
    print()

    print("Done! Verify in the DynamoDB console.")


if __name__ == "__main__":
    main()
