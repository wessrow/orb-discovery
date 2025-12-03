# Quick Start: Exit-on-Completion Mode

## TL;DR
```bash
# Add this flag to exit when all one-time policies complete:
--exit-on-completion
```

## Minimal Example

### 1. Create a policy file (`policy.yaml`)
```yaml
policies:
  my-devices:
    config:
      defaults:
        site: "my-site"
        role: "switch"
    scope:
      - hostname: "192.168.1.1"
        username: "admin"
        password: "password123"
```

### 2. Run with exit-on-completion
```bash
device-discovery \
  --diode-target "grpc://diode.example.com:443" \
  --diode-client-id "my-client-id" \
  --diode-client-secret "my-secret" \
  --exit-on-completion
```

### 3. Submit policy (in another terminal)
```bash
curl -X POST http://localhost:8072/api/v1/policies \
  -H "Content-Type: application/x-yaml" \
  --data-binary @policy.yaml
```

### 4. Application exits when done ✓

## Docker Compose for 500 Devices

### Generate compose file
```bash
python scripts/generate_compose.py \
  --devices devices.csv \
  --batch-size 50 \
  --sequential \
  --output docker-compose.yml
```

### Run it
```bash
export DIODE_TARGET="grpc://diode.example.com:443"
export DIODE_CLIENT_ID="my-client-id"
export DIODE_CLIENT_SECRET="my-secret"

docker-compose up
```

### What happens?
- 10 containers (500 devices ÷ 50 per batch)
- Run sequentially (batch-2 waits for batch-1, etc.)
- Each exits when complete
- Final container exits → all done!

## Important Notes

✅ **DO:**
- Use policies WITHOUT `schedule` field
- One-time discovery runs only
- Check logs for completion status

❌ **DON'T:**
- Use with scheduled policies (they run forever)
- Expect immediate exit (devices need time to discover)
- Rely solely on exit code for success (check logs)

## Files Created

- `device_discovery/policy/runner.py` - Job completion tracking
- `device_discovery/policy/manager.py` - Policy completion aggregation
- `device_discovery/main.py` - Exit-on-completion mode
- `EXIT_ON_COMPLETION.md` - Full documentation
- `scripts/generate_compose.py` - Compose file generator
- `docker/entrypoint.sh` - Auto-submit entrypoint
- `docker-compose-example.yaml` - Example config
- `IMPLEMENTATION_SUMMARY.md` - Technical details

## Need Help?

Check the full documentation:
- [EXIT_ON_COMPLETION.md](EXIT_ON_COMPLETION.md) - User guide
- [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) - Technical details
