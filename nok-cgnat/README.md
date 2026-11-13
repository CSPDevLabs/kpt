# nok-cgnat

Observability package for the **CG-NAT (DS-Lite + stateful inter-chassis redundancy)** recipe. Same layout as `nok-bng`: namespace, syslog-ng, Promtail, Loki, Fluent Bit, Grafana, Prometheus, gNMIc operator sidecars, portal ingress.

Syslog LoadBalancer IP is the `syslog-lb-ip` setter (KinD default `172.18.0.104`).
CG-NAT nodes send **local5** (NAT events) and **local6** (ISA flow records) to that address.

Install with NetOpsKube:

```bash
make try-nok
make install-cgnat-pkg
# or
make try-nok-cgnat
```
