#!/bin/bash
# Entrypoint script for device-discovery with policy auto-submission
# This script starts the discovery service and automatically submits a policy file

set -e

POLICY_FILE="${POLICY_FILE:-/policies/policy.yaml}"
SERVER_HOST="${SERVER_HOST:-0.0.0.0}"
SERVER_PORT="${SERVER_PORT:-8072}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"

echo "Device Discovery Entrypoint Script"
echo "==================================="

# Check if policy file exists
if [ ! -f "$POLICY_FILE" ]; then
    echo "ERROR: Policy file not found: $POLICY_FILE"
    echo "Mount your policy file to $POLICY_FILE or set POLICY_FILE environment variable"
    exit 1
fi

echo "Starting device-discovery service..."

# Start device discovery in background
device-discovery \
    --host "$SERVER_HOST" \
    --port "$SERVER_PORT" \
    --diode-target "${DIODE_TARGET}" \
    --diode-client-id "${DIODE_CLIENT_ID}" \
    --diode-client-secret "${DIODE_CLIENT_SECRET}" \
    ${DIODE_APP_NAME_PREFIX:+--diode-app-name-prefix "$DIODE_APP_NAME_PREFIX"} \
    ${DRY_RUN:+--dry-run} \
    ${DRY_RUN_OUTPUT_DIR:+--dry-run-output-dir "$DRY_RUN_OUTPUT_DIR"} \
    ${OTEL_ENDPOINT:+--otel-endpoint "$OTEL_ENDPOINT"} \
    ${OTEL_EXPORT_PERIOD:+--otel-export-period "$OTEL_EXPORT_PERIOD"} \
    ${EXIT_ON_COMPLETION:+--exit-on-completion} &

DISCOVERY_PID=$!

echo "Device discovery started (PID: $DISCOVERY_PID)"
echo "Waiting for service to be ready..."

# Wait for server to be ready
ELAPSED=0
until curl -sf "http://localhost:${SERVER_PORT}/api/v1/status" > /dev/null 2>&1; do
    if [ $ELAPSED -ge $WAIT_TIMEOUT ]; then
        echo "ERROR: Service did not become ready within ${WAIT_TIMEOUT} seconds"
        kill $DISCOVERY_PID 2>/dev/null || true
        exit 1
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

echo "Service is ready!"
echo "Submitting policy from: $POLICY_FILE"

# Submit policy
HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/policy-response.txt \
    -X POST "http://localhost:${SERVER_PORT}/api/v1/policies" \
    -H "Content-Type: application/x-yaml" \
    --data-binary "@${POLICY_FILE}")

if [ "$HTTP_CODE" = "201" ]; then
    echo "Policy submitted successfully!"
    cat /tmp/policy-response.txt
    echo ""
else
    echo "ERROR: Failed to submit policy (HTTP $HTTP_CODE)"
    cat /tmp/policy-response.txt
    echo ""
    kill $DISCOVERY_PID 2>/dev/null || true
    exit 1
fi

# If exit-on-completion is set, wait for process to exit
if [ -n "$EXIT_ON_COMPLETION" ]; then
    echo "Waiting for all policies to complete..."
    wait $DISCOVERY_PID
    EXIT_CODE=$?
    echo "Discovery completed with exit code: $EXIT_CODE"
    exit $EXIT_CODE
else
    echo "Running in continuous mode. Service will not auto-exit."
    wait $DISCOVERY_PID
fi
