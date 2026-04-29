#!/usr/bin/env bash
#
# Deploy the prod Lambda safely. main only has one stack (formula-helper),
# so this script takes no arguments.
#
# Safety gates, in order:
#   1. AWS profile auth + account-ID assertion (prevents wrong-account deploys).
#   2. `sam build --use-container` — forces Linux wheels via Docker, otherwise
#      cbor2/cffi/cryptography wheels can silently fail to resolve on macOS
#      and ship a Lambda missing the webauthn package (caught us once).
#   3. Build-artifact assertion: the package must contain webauthn/.
#   4. sam deploy.
#   5. Post-deploy smoke: POST /api/auth/login-options must return 200. A
#      module-import error (e.g. missing dependency) surfaces as 500 here,
#      so any non-200 fails the deploy and prints a hint to grep CloudWatch.

set -euo pipefail

EXPECTED_ACCOUNT="269469693968"
PROFILE="viper"
STACK="formula-helper"
REGION="us-east-1"
SMOKE_URL="https://d20oyc88hlibbe.cloudfront.net/api/auth/login-options"
LOG_GROUP="/aws/lambda/formula-helper-FormulaFunction-zStTzpfYgsZt"

echo "→ checking ${PROFILE} account identity..."
ACCOUNT=$(aws sts get-caller-identity --profile "${PROFILE}" --query Account --output text 2>/dev/null) || {
    echo "✗ could not authenticate with profile '${PROFILE}'. Run: aws sso login --profile ${PROFILE}"
    exit 1
}
if [[ "${ACCOUNT}" != "${EXPECTED_ACCOUNT}" ]]; then
    echo "✗ wrong account: expected ${EXPECTED_ACCOUNT}, got ${ACCOUNT}"
    exit 1
fi
echo "  ${ACCOUNT} ✓"

if ! docker info > /dev/null 2>&1; then
    echo "✗ Docker is not running. Start Docker Desktop, then retry."
    echo "  --use-container is required because cbor2/cryptography wheels need"
    echo "  manylinux Linux builds; without Docker, sam build silently produces"
    echo "  an incomplete package and the deployed Lambda 500s on import."
    exit 1
fi

echo "→ sam build --use-container..."
sam build --template-file template.yaml --use-container > /tmp/sam-build-$$.log 2>&1 || {
    echo "✗ sam build failed. Tail of log:"
    tail -20 /tmp/sam-build-$$.log
    exit 1
}

echo "→ verifying build artifact contains webauthn..."
if ! test -d .aws-sam/build/FormulaFunction/webauthn; then
    echo "✗ webauthn/ missing from .aws-sam/build/FormulaFunction — refusing to deploy."
    exit 1
fi

echo "→ sam deploy..."
sam deploy \
    --profile "${PROFILE}" \
    --stack-name "${STACK}" \
    --capabilities CAPABILITY_IAM \
    --no-confirm-changeset \
    --resolve-s3 \
    --region "${REGION}" > /tmp/sam-deploy-$$.log 2>&1 || {
    echo "✗ sam deploy failed. Tail of log:"
    tail -20 /tmp/sam-deploy-$$.log
    exit 1
}

echo "→ smoke test: POST ${SMOKE_URL}"
HTTP=$(curl -s -o /tmp/smoke-body-$$.json -w "%{http_code}" -X POST \
    "${SMOKE_URL}" \
    -H 'Content-Type: application/json' \
    -d '{}')
if [[ "${HTTP}" != "200" ]]; then
    echo "✗ smoke test failed: HTTP ${HTTP} (expected 200)"
    echo "  Body:"
    head -c 500 /tmp/smoke-body-$$.json | sed 's/^/    /'
    echo
    echo "  Lambda likely has an import or runtime error."
    echo "  Tail logs:  aws --profile ${PROFILE} logs tail ${LOG_GROUP} --since 5m"
    exit 1
fi

# Defense in depth: assert the response shape looks like a real WebAuthn challenge.
if ! grep -q '"challenge"' /tmp/smoke-body-$$.json; then
    echo "✗ smoke test got 200 but response is missing a 'challenge' field — something is wrong."
    head -c 500 /tmp/smoke-body-$$.json | sed 's/^/    /'
    exit 1
fi

echo "✓ deployed and smoke-tested clean"
