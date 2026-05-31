"""
Shared test fixtures for Formula Helper tests.
Uses moto to mock DynamoDB and patches ntfy/external calls.
"""

import json
import os
import sys
import time
import pytest

# Set env vars before importing handler
os.environ["TABLE_NAME"] = "FormulaHelper"
os.environ["NTFY_TOPIC"] = "test-topic"
os.environ["PI_API_KEY"] = "test-pi-key"
os.environ["RP_ID"] = "localhost"
os.environ["RP_ORIGIN"] = "https://localhost"
os.environ["VAPID_PRIVATE_KEY"] = ""
os.environ["VAPID_PUBLIC_KEY"] = ""

# Add lambda/ to sys.path so handler can be imported directly
_lambda_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "lambda")
if _lambda_dir not in sys.path:
    sys.path.insert(0, _lambda_dir)


@pytest.fixture(autouse=True)
def mock_dynamodb():
    """Create a mock DynamoDB table for every test."""
    import boto3
    from moto import mock_aws

    with mock_aws():
        # Create mock table
        client = boto3.client("dynamodb", region_name="us-east-1")
        client.create_table(
            TableName="FormulaHelper",
            KeySchema=[
                {"AttributeName": "PK", "KeyType": "HASH"},
                {"AttributeName": "SK", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "PK", "AttributeType": "S"},
                {"AttributeName": "SK", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )

        # Import and patch handler's DynamoDB references
        import handler as handler_module
        mock_dynamodb_resource = boto3.resource("dynamodb", region_name="us-east-1")
        mock_table = mock_dynamodb_resource.Table("FormulaHelper")
        handler_module.dynamodb = mock_dynamodb_resource
        handler_module.table = mock_table

        yield handler_module


@pytest.fixture
def handler(mock_dynamodb):
    """Return the handler module with mocked DynamoDB."""
    return mock_dynamodb


@pytest.fixture
def table(handler):
    """Return the DynamoDB table resource."""
    return handler.table


def make_event(route_key, body=None, path_params=None, headers=None, cookies=None):
    """Build a mock API Gateway HTTP API event."""
    event = {
        "routeKey": route_key,
        "headers": headers or {},
        "pathParameters": path_params or {},
    }
    if body is not None:
        event["body"] = json.dumps(body)
    if cookies:
        event["cookies"] = cookies
    return event


def parse_response(response):
    """Parse a Lambda response into (status, body_dict)."""
    status = response["statusCode"]
    body = json.loads(response["body"]) if response.get("body") else {}
    return status, body
