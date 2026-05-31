import json
import boto3

s3 = boto3.client("s3")
BUCKET = "formula-helper-backup"


def handler(event, context):
    try:
        body = json.loads(event.get("body", "{}"))
        log_data = body.get("log", [])

        s3.put_object(
            Bucket=BUCKET,
            Key="mix_log.json",
            Body=json.dumps(log_data, indent=2),
            ContentType="application/json",
        )

        return {
            "statusCode": 200,
            "body": json.dumps({"ok": True, "entries": len(log_data)}),
        }
    except Exception as e:
        return {
            "statusCode": 500,
            "body": json.dumps({"ok": False, "error": str(e)}),
        }
