# orb-discovery

Orb discovery backends collection

- [device-discovery](./device-discovery/README.md) - Device Discovery Backend that uses [NAPALM](https://github.com/napalm-automation/napalm) Drivers.
- [network-discovery](./network-discovery/README.md) - Network Discovery Backend which is a wrapper over [NMAP](https://nmap.org/) scanner.
- [worker](./worker/README.md) - A Worker Backend that allows to run custom implementation as part of Orb Agent.
- [snmp-discover](./snmp-discovery/README.md) - Device discovery that uses SNMP

# LOCAL TEST

Example test-policy.yaml
```
misc: &device_credentials
  username: <device-user>
  password: <device-password>
policies:
  discovery_1:
    config:
      defaults:
        site: sko-skovde-stationsg3
    scope:
      - hostname: 10.33.160.161
```

Start test-policy.yaml
```
curl -X POST -H "Content-Type: application/x-yaml" --data-binary @test-policy.yaml http://localhost:8072/api/v1/policies
```

Delete test-policy.yaml
```
curl -X DELETE  http://localhost:8072/api/v1/policies/discovery_1
```