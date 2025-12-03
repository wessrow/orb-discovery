# Exit-on-Completion Mode for Container Orchestration

## Overview

The device discovery application now supports an `--exit-on-completion` mode that allows the application to exit with code 0 when all one-time (non-scheduled) policies have completed. This is specifically designed for container orchestration scenarios where you need to chain multiple discovery jobs using `depends_on` with `service_completed_successfully`.

## Use Case

This feature is ideal for scenarios where you need to:
- Run device discovery in batches across hundreds or thousands of devices
- Chain discovery jobs in a specific order
- Use Docker Compose or Kubernetes Jobs for orchestration
- Ensure proper completion before starting dependent services

## How It Works

### Normal Mode (default)
```bash
device-discovery --host 0.0.0.0 --port 8072 \
  --diode-target $DIODE_TARGET \
  --diode-client-id $DIODE_CLIENT_ID \
  --diode-client-secret $DIODE_CLIENT_SECRET
```
- Server runs indefinitely
- Accepts policy submissions via API
- Continues running even after policies complete

### Exit-on-Completion Mode
```bash
device-discovery --host 0.0.0.0 --port 8072 \
  --diode-target $DIODE_TARGET \
  --diode-client-id $DIODE_CLIENT_ID \
  --diode-client-secret $DIODE_CLIENT_SECRET \
  --exit-on-completion
```
- Server runs in background thread
- Accepts policy submissions via API
- **Exits with code 0** when all one-time policies complete
- Only one-time policies (no `schedule` field) trigger exit
- Scheduled policies (with cron) are ignored for exit detection

## Behavior Details

### What Counts as "Completed"?
A policy is considered completed when:
1. It has **no schedule** (one-time run)
2. All devices in the policy's scope have been processed
3. Processing includes both successful and failed attempts

### What Doesn't Trigger Exit?
- Policies with a `schedule` field (cron jobs)
- Long-running scheduled policies continue indefinitely
- Use this mode ONLY with one-time policies

### Exit Code
- **0**: All one-time policies completed successfully (even if some devices failed)
- **Non-zero**: Application error before completion

## Docker Compose Example

### Single Container
```yaml
services:
  device-discovery:
    image: netboxlabs/orb-device-discovery:latest
    command: >
      device-discovery
      --exit-on-completion
      --diode-target ${DIODE_TARGET}
      --diode-client-id ${DIODE_CLIENT_ID}
      --diode-client-secret ${DIODE_CLIENT_SECRET}
    environment:
      - DIODE_TARGET
      - DIODE_CLIENT_ID
      - DIODE_CLIENT_SECRET
```

### Chained Containers (500+ services)
```yaml
services:
  discovery-batch-001:
    image: netboxlabs/orb-device-discovery:latest
    command: device-discovery --exit-on-completion ...
    
  discovery-batch-002:
    image: netboxlabs/orb-device-discovery:latest
    command: device-discovery --exit-on-completion ...
    depends_on:
      discovery-batch-001:
        condition: service_completed_successfully
        
  discovery-batch-003:
    image: netboxlabs/orb-device-discovery:latest
    command: device-discovery --exit-on-completion ...
    depends_on:
      discovery-batch-002:
        condition: service_completed_successfully
        
  # ... Continue for 500+ services
```

## Submitting Policies

You still need to submit policies via the REST API. Here are some approaches:

### 1. Init Container (Kubernetes)
```yaml
initContainers:
- name: submit-policy
  image: curlimages/curl:latest
  command:
  - sh
  - -c
  - |
    until curl -f http://device-discovery:8072/api/v1/status; do
      sleep 1
    done
    curl -X POST http://device-discovery:8072/api/v1/policies \
      -H "Content-Type: application/x-yaml" \
      --data-binary @/policies/policy.yaml
  volumeMounts:
  - name: policy
    mountPath: /policies
```

### 2. Sidecar Container (Docker Compose)
```yaml
services:
  device-discovery:
    image: netboxlabs/orb-device-discovery:latest
    command: device-discovery --exit-on-completion ...
    
  policy-submitter:
    image: curlimages/curl:latest
    command: >
      sh -c "
      sleep 5 &&
      curl -X POST http://device-discovery:8072/api/v1/policies
      -H 'Content-Type: application/x-yaml'
      --data-binary @/policy.yaml
      "
    volumes:
      - ./policy.yaml:/policy.yaml:ro
    depends_on:
      - device-discovery
```

### 3. Entrypoint Script
Create a custom entrypoint that:
1. Starts the server in background
2. Waits for it to be ready
3. Submits the policy
4. Waits for completion

```bash
#!/bin/bash
# Start device discovery in background
device-discovery --exit-on-completion \
  --diode-target "$DIODE_TARGET" \
  --diode-client-id "$DIODE_CLIENT_ID" \
  --diode-client-secret "$DIODE_CLIENT_SECRET" &

DISCOVERY_PID=$!

# Wait for server to be ready
until curl -f http://localhost:8072/api/v1/status; do
  sleep 1
done

# Submit policy
curl -X POST http://localhost:8072/api/v1/policies \
  -H "Content-Type: application/x-yaml" \
  --data-binary @/policies/policy.yaml

# Wait for discovery to complete
wait $DISCOVERY_PID
```

## Policy Format

Ensure your policies do NOT have a `schedule` field for exit-on-completion to work:

```yaml
# ✅ CORRECT - Will trigger exit on completion
policies:
  my-devices:
    config:
      defaults:
        site: "datacenter-01"
        role: "access-switch"
    scope:
      - hostname: "192.168.1.1"
        username: "admin"
        password: "${DEVICE_PASSWORD}"
      - hostname: "192.168.1.2"
        username: "admin"
        password: "${DEVICE_PASSWORD}"
```

```yaml
# ❌ INCORRECT - Will NOT trigger exit (scheduled job)
policies:
  my-devices:
    config:
      schedule: "*/5 * * * *"  # This makes it a recurring job
      defaults:
        site: "datacenter-01"
    scope:
      - hostname: "192.168.1.1"
        username: "admin"
        password: "${DEVICE_PASSWORD}"
```

## Monitoring and Logging

The application logs completion status:

```
INFO - Policy my-devices: Job completed (1/10)
INFO - Policy my-devices: Job completed (2/10)
...
INFO - Policy my-devices: Job completed (10/10)
INFO - Policy my-devices: All one-time jobs completed
INFO - All one-time policies completed
INFO - All policies completed. Exiting application...
```

## Troubleshooting

### Container Never Exits
- Check that policies have NO `schedule` field
- Verify policies were successfully submitted (check API logs)
- Ensure devices are reachable (failed devices still count as completed)

### Container Exits Too Early
- You may have accidentally used `--exit-on-completion` with scheduled policies
- Check if some policies finished before others were submitted

### Container Exits with Non-Zero Code
- Check application logs for errors
- Verify credentials and connectivity
- Ensure Diode target is reachable

## Architecture Notes

### Implementation Details
1. **PolicyRunner** tracks completion of one-time jobs
   - Maintains count of total jobs and completed jobs
   - Invokes callback when all jobs complete
   
2. **PolicyManager** aggregates completion across policies
   - Checks if all one-time policies are complete
   - Triggers exit callback when all are done
   
3. **Main Application** coordinates shutdown
   - Runs server in daemon thread when exit-on-completion enabled
   - Waits for completion signal
   - Performs clean shutdown and exits with code 0

### Thread Safety
- Uses threading.Event for synchronization
- Background scheduler handles job execution
- Main thread waits for completion signal

## Migration Guide

### From Long-Running Service
If you're currently running discovery as a long-running service:

**Before:**
- Single container running 24/7
- Policies submitted via API as needed
- No container restarts needed

**After (with exit-on-completion):**
- Multiple containers for batches
- Each container handles a subset of devices
- Containers exit after completion
- Use orchestration for sequencing

### Hybrid Approach
You can run both modes:
- Long-running service for scheduled/recurring discovery
- Batch containers with exit-on-completion for one-time operations

## Performance Considerations

- Each container has startup overhead (~1-5 seconds)
- For 500 containers, consider parallel execution limits
- Balance between parallelism and resource usage
- Consider grouping devices to reduce container count

## Best Practices

1. **Batch Size**: Group 10-50 devices per container for optimal performance
2. **Timeouts**: Set appropriate device timeouts based on network latency
3. **Resource Limits**: Set memory/CPU limits in orchestration config
4. **Error Handling**: Failed devices still trigger completion - check logs
5. **Testing**: Test with small batches before scaling to 500+ containers

## Example: 500-Device Deployment

For 500 devices, consider:
- 10 containers × 50 devices each
- Sequential execution (safe, slower)
- Or parallel execution (faster, more resources)

```bash
# Generate compose file for 500 devices
python generate_compose.py \
  --devices devices.csv \
  --batch-size 50 \
  --output docker-compose.yml
```
