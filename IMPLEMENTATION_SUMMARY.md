# Exit-on-Completion Feature Implementation Summary

## Overview
Modified the device-discovery application to support an `--exit-on-completion` mode that allows the application to exit with code 0 when all one-time (non-scheduled) policies have completed. This enables container orchestration with `depends_on` and `service_completed_successfully` for chaining hundreds of discovery containers.

## Changes Made

### 1. Policy Runner (`device_discovery/policy/runner.py`)
**Added:**
- `is_one_time`: Boolean flag to track if policy has no schedule
- `total_jobs`: Count of total jobs in one-time policy
- `completed_jobs`: Count of completed jobs
- `on_completion_callback`: Callback function for completion notification

**Modified:**
- `setup()`: Now accepts optional `on_completion_callback` parameter and tracks job counts
- `run()`: Calls `_mark_job_completed()` in finally block to ensure completion tracking
- `_discover_driver()`: Calls `_mark_job_completed()` on early return

**New Methods:**
- `_mark_job_completed()`: Increments completed count and triggers callback when all jobs done
- `is_completed()`: Returns whether all one-time jobs are complete

### 2. Policy Manager (`device_discovery/policy/manager.py`)
**Added:**
- `exit_on_completion`: Boolean flag for exit mode
- `on_all_completed_callback`: Callback to trigger when all policies complete

**New Methods:**
- `set_exit_on_completion(callback)`: Enable exit-on-completion mode
- `_on_policy_completed(policy_name)`: Check if all one-time policies are done

**Modified:**
- `start_policy()`: Passes completion callback to runner when in exit mode

### 3. Main Application (`device_discovery/main.py`)
**Added:**
- `--exit-on-completion` CLI argument

**Modified:**
- Main function now supports two modes:
  - **Normal mode**: Runs uvicorn directly (blocking)
  - **Exit-on-completion mode**: Runs server in daemon thread, waits for completion signal, then exits with code 0

## How It Works

### Flow Diagram
```
1. Application starts with --exit-on-completion flag
2. Manager.set_exit_on_completion() is called with exit callback
3. Server runs in background thread
4. Policies submitted via API
5. Each PolicyRunner tracks job completion
6. When a policy completes all jobs → calls Manager._on_policy_completed()
7. Manager checks if ALL one-time policies are complete
8. If all complete → triggers exit callback
9. Main thread receives signal
10. Clean shutdown
11. Exit with code 0
```

### Key Design Decisions

1. **Only One-Time Policies Trigger Exit**
   - Policies without `schedule` field are one-time
   - Scheduled policies (cron) don't affect exit logic
   - This allows mixing scheduled and one-time policies

2. **Thread-Based Coordination**
   - Server runs in daemon thread when exit-on-completion enabled
   - Main thread waits on threading.Event
   - Clean shutdown before exit

3. **Completion = All Jobs Processed**
   - Both successful and failed jobs count as "completed"
   - Exit code 0 even if some devices failed
   - Check logs for individual device failures

4. **Backward Compatible**
   - Default behavior unchanged (runs indefinitely)
   - Opt-in via CLI flag
   - No API changes required

## Usage Examples

### Basic Usage
```bash
device-discovery \
  --host 0.0.0.0 \
  --port 8072 \
  --diode-target $DIODE_TARGET \
  --diode-client-id $DIODE_CLIENT_ID \
  --diode-client-secret $DIODE_CLIENT_SECRET \
  --exit-on-completion
```

### Docker Container
```dockerfile
FROM netboxlabs/orb-device-discovery:latest
CMD ["device-discovery", "--exit-on-completion", ...]
```

### Docker Compose with Chaining
```yaml
services:
  batch-1:
    image: netboxlabs/orb-device-discovery:latest
    command: device-discovery --exit-on-completion ...
  
  batch-2:
    image: netboxlabs/orb-device-discovery:latest
    command: device-discovery --exit-on-completion ...
    depends_on:
      batch-1:
        condition: service_completed_successfully
```

### Policy Format (One-Time)
```yaml
policies:
  my-batch:
    config:
      defaults:
        site: "datacenter-01"
    scope:
      - hostname: "192.168.1.1"
        username: "admin"
        password: "${PASSWORD}"
      - hostname: "192.168.1.2"
        username: "admin"
        password: "${PASSWORD}"
```

## Helper Tools Created

### 1. `docker/entrypoint.sh`
Bash script that:
- Starts discovery service
- Waits for it to be ready
- Auto-submits policy from file
- Waits for completion if in exit-on-completion mode

### 2. `scripts/generate_compose.py`
Python script that:
- Reads devices from CSV
- Generates batched compose files
- Creates policy files for each batch
- Supports sequential or parallel execution
- Handles 500+ containers

### 3. Documentation
- `EXIT_ON_COMPLETION.md`: Comprehensive user guide
- `docker-compose-example.yaml`: Example configuration
- `scripts/example-devices.csv`: Sample device list

## Testing Recommendations

### Unit Tests
```python
def test_policy_runner_one_time_completion():
    """Test that one-time policies track completion correctly."""
    runner = PolicyRunner()
    callback_called = False
    
    def callback(name):
        nonlocal callback_called
        callback_called = True
    
    # Setup with no schedule (one-time)
    config = Config(defaults=Defaults())
    scopes = [mock_scope_1, mock_scope_2]
    runner.setup("test", config, scopes, on_completion_callback=callback)
    
    assert runner.is_one_time
    assert runner.total_jobs == 2
    
    # Simulate job completions
    runner._mark_job_completed()
    assert not callback_called
    
    runner._mark_job_completed()
    assert callback_called
    assert runner.is_completed()
```

### Integration Tests
1. Start server with `--exit-on-completion`
2. Submit one-time policy via API
3. Verify server exits with code 0 after completion
4. Check logs for completion messages

### Load Tests
1. Generate compose with 500 services
2. Use dummy/mock policies (no actual devices)
3. Verify proper sequential execution
4. Monitor resource usage

## Deployment Considerations

### For 500+ Containers

**Resource Requirements:**
- Each container: ~50-100MB memory
- CPU: Minimal when idle, spikes during discovery
- Network: Depends on device count and data volume

**Strategies:**
1. **Sequential Execution**
   - Safest approach
   - Slower (500 × avg_discovery_time)
   - Minimal resource usage

2. **Parallel Batches**
   - Group into waves (e.g., 10 parallel batches)
   - Balance speed vs resources
   - Use `--parallel-batches` flag

3. **Full Parallel**
   - Fastest but resource-intensive
   - Requires significant host resources
   - May overwhelm network/Diode

**Recommended Approach:**
- Batch size: 20-50 devices per container
- Parallel batches: 5-10 at a time
- Total time: ~10-20 minutes for 500 devices

### Kubernetes Alternative
For Kubernetes, consider using Jobs instead:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: device-discovery-batch-001
spec:
  template:
    spec:
      containers:
      - name: discovery
        image: netboxlabs/orb-device-discovery:latest
        args: ["--exit-on-completion", ...]
      restartPolicy: Never
```

## Monitoring

### Logs to Watch
```
INFO - Policy {name}: Job completed (1/10)
INFO - Policy {name}: All one-time jobs completed
INFO - All one-time policies completed
INFO - All policies completed. Exiting application...
```

### Metrics
- `active_policies`: Number of running policies
- `discovery_attempts`: Total discovery attempts
- `discovery_success`: Successful discoveries
- `discovery_failure`: Failed discoveries

### Health Checks
```bash
# Check if service is running
curl http://localhost:8072/api/v1/status

# Check if policy exists
curl http://localhost:8072/api/v1/policies/{name}
```

## Troubleshooting

### Container Never Exits
- Verify policy has no `schedule` field
- Check policy was submitted successfully
- Look for errors in logs

### Container Exits Too Soon
- Check if policy has devices
- Verify callback is triggered correctly
- Ensure all jobs complete

### Exit Code Non-Zero
- Application error before completion
- Check logs for exceptions
- Verify credentials and connectivity

## Future Enhancements

Possible improvements:
1. **Progress API**: Endpoint to query completion percentage
2. **Webhook Notifications**: Call webhook on completion
3. **Partial Completion**: Exit after N% of devices
4. **Timeout Support**: Exit after max duration
5. **Graceful Cancellation**: Support SIGTERM for early exit

## Migration Path

### From Existing Deployment
1. Test with small batches first
2. Validate exit behavior
3. Scale up gradually
4. Monitor resource usage
5. Adjust batch sizes as needed

### Rollback Plan
- Original code is backward compatible
- Simply omit `--exit-on-completion` flag
- No data/state changes made

## Conclusion

This implementation provides a robust solution for orchestrating large-scale device discovery using container dependencies. The exit-on-completion mode enables reliable chaining of hundreds of containers while maintaining backward compatibility with existing deployments.
