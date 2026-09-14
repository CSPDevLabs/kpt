# kpt recipe validation (Epic 9)

Validates **BNG** and **DIA** recipe packages before merge or publish. No KinD cluster or Docker required.

## Run

```bash
make test
# or
./test/validate-recipes.sh
```

## Checks

- `Kptfile` exists with `apply-setters` pipeline
- Required setter keys in `apply-setters.yaml` (syslog LB IPs, ingress, MetalLB pool, Gitea SSH)
- Recipe files present (`ingress`, gitea-proxy, bbm-grafana-proxy, etc.)
- Unified portal menu in `nok-base/portal/portal-menu-config.yaml` (`openInNewTab: false`)
- Portal in-iframe behaviour (ingress `proxy-hide-headers`, `/gitea` route on BNG/DIA)
- Gitea sub-path config in `nok-git` (no standalone Gitea ingress)
- BBM Grafana `allow_embedding` and `root_url` with KinD portal port (`:8080`)
- Kptfile pipeline images use `ghcr.io/kptdev/krm-functions-catalog/*` (not deprecated `gcr.io/kpt-fn/*`)
- All YAML under `nok-bng/` and `nok-dia/` parses

## kpt fn render and gcr.io

`gcr.io/kpt-fn/*` images were **removed/migrated** to `ghcr.io/kptdev/krm-functions-catalog/*`. If `kpt fn render` fails pulling `gcr.io` images, that is **not environment-specific** — update `Kptfile` image references (already done in this repo) or use `make update-kpt-lb-setters` + `kpt live apply` without render.

## CI

GitHub Actions runs `make test` on push to `main` only (`.github/workflows/validate-recipes.yml`).
