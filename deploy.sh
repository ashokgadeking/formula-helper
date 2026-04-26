#!/bin/bash
# Guarded deploy. Asserts the AWS account matches the target environment before running sam.
# Usage: ./deploy.sh dev    → profile=javelin, stack=formula-helper-dev
#        ./deploy.sh prod   → profile=viper,   stack=formula-helper  (prompts changeset)
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  dev)
    PROFILE="javelin"
    EXPECTED_ACCOUNT="598771460994"
    CONFIG="samconfig-dev.toml"
    ;;
  prod)
    PROFILE="viper"
    EXPECTED_ACCOUNT="269469693968"
    CONFIG="samconfig-prod.toml"
    ;;
  *)
    echo "usage: $0 dev|prod" >&2
    exit 2
    ;;
esac

echo "→ checking $PROFILE account identity..."
ACTUAL_ACCOUNT=$(AWS_PROFILE="$PROFILE" aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACTUAL_ACCOUNT" ]; then
  echo "✗ could not authenticate with profile '$PROFILE'. Run: aws sso login --profile $PROFILE" >&2
  exit 1
fi
if [ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
  echo "✗ account mismatch — profile '$PROFILE' is in account $ACTUAL_ACCOUNT, expected $EXPECTED_ACCOUNT" >&2
  exit 1
fi
echo "✓ account $ACTUAL_ACCOUNT matches $ENV"

echo "→ sam build (--config-file $CONFIG)"
sam build --config-file "$CONFIG"
echo "→ sam deploy (--config-file $CONFIG)"
sam deploy --config-file "$CONFIG"
