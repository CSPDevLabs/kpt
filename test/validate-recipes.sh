#!/usr/bin/env bash
# Epic 9 — validate kpt recipe packages before publish (no KinD cluster required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YQ="${YQ:-yq}"

if ! command -v "$YQ" >/dev/null 2>&1; then
  echo "[FAIL] yq not found (set YQ=path/to/yq)" >&2
  exit 1
fi

RECIPE_PACKAGES=(nok-bng nok-dia)
REQUIRED_SETTERS=(
  "nok-bng:syslog-lb-ip"
  "nok-dia:syslog-lb-ip"
  "nok-base:ingress-lb-ip"
  "nok-lb:metallb-pool-range"
  "nok-git:gitea-ssh-lb-ip"
)
RECIPE_REQUIRED_FILES=(
  "nok-bng:Kptfile"
  "nok-bng:apply-setters.yaml"
  "nok-bng:portal/portal-health-ingress.yaml"
  "nok-bng:portal/portal-menu-config.yaml"
  "nok-bng:portal/portal-gitea-proxy-svc.yaml"
  "nok-bng:ingress/ingress.yaml"
  "nok-dia:Kptfile"
  "nok-dia:apply-setters.yaml"
  "nok-dia:portal/portal-health-ingress.yaml"
  "nok-dia:portal/portal-menu-config.yaml"
  "nok-dia:portal/portal-gitea-proxy-svc.yaml"
  "nok-dia:ingress/ingress.yaml"
)

pass=0
fail=0

ok()   { echo "    [PASS] $*"; pass=$((pass + 1)); }
bad()  { echo "    [FAIL] $*" >&2; fail=$((fail + 1)); }

echo "--> KPT: Validating recipe packages (Epic 9)"

for pkg in "${RECIPE_PACKAGES[@]}"; do
  if [[ -f "$ROOT/$pkg/Kptfile" ]]; then
    ok "$pkg/Kptfile exists"
  else
    bad "$pkg/Kptfile missing"
  fi
  if grep -q 'apply-setters' "$ROOT/$pkg/Kptfile" 2>/dev/null; then
    ok "$pkg pipeline includes apply-setters"
  else
    bad "$pkg Kptfile missing apply-setters mutator"
  fi
done

for entry in "${REQUIRED_SETTERS[@]}"; do
  pkg="${entry%%:*}"
  key="${entry#*:}"
  file="$ROOT/$pkg/apply-setters.yaml"
  if [[ ! -f "$file" ]]; then
    bad "$pkg/apply-setters.yaml missing"
    continue
  fi
  val="$("$YQ" eval ".data.\"$key\"" "$file" 2>/dev/null || true)"
  if [[ -n "$val" && "$val" != "null" ]]; then
    ok "$pkg setter $key=$val"
  else
    bad "$pkg setter $key not set in apply-setters.yaml"
  fi
done

for entry in "${RECIPE_REQUIRED_FILES[@]}"; do
  pkg="${entry%%:*}"
  rel="${entry#*:}"
  if [[ -f "$ROOT/$pkg/$rel" ]]; then
    ok "$pkg/$rel exists"
  else
    bad "$pkg/$rel missing"
  fi
done

echo "--> KPT: Portal in-iframe embedding (recipe-owned, no NetOpsKube overlay)"
for recipe in nok-bng nok-dia; do
  menu="$ROOT/$recipe/portal/portal-menu-config.yaml"
  if grep -q '"openInNewTab": true' "$menu" 2>/dev/null; then
    bad "$recipe portal menu still opens items in a new tab"
  else
    ok "$recipe portal menu uses in-portal navigation"
  fi
  ingress="$ROOT/$recipe/ingress/ingress.yaml"
  if grep -q 'proxy-hide-headers: "X-Frame-Options"' "$ingress" 2>/dev/null; then
    ok "$recipe ingress strips X-Frame-Options for iframe embedding"
  else
    bad "$recipe ingress missing proxy-hide-headers for X-Frame-Options"
  fi
  if grep -q '/gitea' "$ingress" 2>/dev/null; then
    ok "$recipe ingress routes /gitea through gitea-proxy"
  else
    bad "$recipe ingress missing /gitea path"
  fi
done

gitea_manifest="$ROOT/nok-git/gitea/gitea-manifest-standalone.yaml"
if [[ -f "$gitea_manifest" ]]; then
  if grep -q 'SERVE_FROM_SUB_PATH=true' "$gitea_manifest" && grep -q 'ROOT_URL=http://bng.nok.local:8080/gitea/' "$gitea_manifest"; then
    ok "nok-git Gitea configured for portal sub-path"
  else
    bad "nok-git Gitea missing SERVE_FROM_SUB_PATH or portal ROOT_URL"
  fi
  if [[ -f "$ROOT/nok-git/gitea/ingress.yaml" ]]; then
    bad "nok-git still has standalone gitea/ingress.yaml (should use recipe ingress)"
  else
    ok "nok-git has no standalone Gitea ingress (recipe ingress owns /gitea)"
  fi
fi

bbm_grafana="$ROOT/nok-bbm/grafana/instance/grafana.yml"
if grep -q 'allow_embedding: "true"' "$bbm_grafana" 2>/dev/null; then
  ok "nok-bbm Grafana allows iframe embedding"
else
  bad "nok-bbm Grafana missing allow_embedding"
fi

echo "--> KPT: Kptfile function images use ghcr.io (gcr.io/kpt-fn is deprecated)"
for kptfile in "$ROOT"/nok-*/Kptfile; do
  pkg="$(basename "$(dirname "$kptfile")")"
  if grep -q 'gcr.io/kpt-fn' "$kptfile" 2>/dev/null; then
    bad "$pkg Kptfile still references deprecated gcr.io/kpt-fn images"
  else
    ok "$pkg Kptfile uses current function image registry"
  fi
done

echo "--> KPT: Parsing YAML under recipe packages"
while IFS= read -r -d '' yaml; do
  rel="${yaml#"$ROOT/"}"
  if "$YQ" eval '.' "$yaml" >/dev/null 2>&1; then
    ok "valid YAML: $rel"
  else
    bad "invalid YAML: $rel"
  fi
done < <(find "$ROOT/nok-bng" "$ROOT/nok-dia" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

echo ""
if [[ $fail -eq 0 ]]; then
  echo "--> KPT: Recipe validation passed ($pass checks)"
  exit 0
fi

echo "--> KPT: Recipe validation failed ($fail failures, $pass passed)" >&2
exit 1
