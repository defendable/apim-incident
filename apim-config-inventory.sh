#!/usr/bin/env bash
#
# Lists APIM "Named values" and "OAuth 2.0 + OpenID Connect" configurations for every
# API Management instance that belongs to one Azure AD tenant. Resources delegated
# to the tenant via Azure Lighthouse are excluded.
#
# Read-only: uses only GET calls (Reader role is sufficient). Secret values, Key Vault
# secrets and OAuth client secrets are never retrieved.
#
# Requirements: Azure CLI (logged in with `az login`) and jq. Azure Cloud Shell has both.
#
# Usage: ./apim-config-inventory.sh [-t TENANT_ID] [-o OUTPUT_DIR] [-v]
#   -t  Tenant to inventory (default: tenant of the current `az login` session)
#   -o  Output directory (default: current directory)
#   -v  Include values of NON-secret named values and OAuth token body parameters
#
# Output: apim-config-<tenant>-<timestamp>.json and .txt

set -euo pipefail

API="2022-08-01"
TENANT=""; OUT_DIR="."; VALUES=false

while getopts ":t:o:vh" opt; do
  case "$opt" in
    t) TENANT="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    v) VALUES=true ;;
    *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
done

for c in az jq; do command -v "$c" >/dev/null || { echo "Missing dependency: $c" >&2; exit 1; }; done
az account show -o none 2>/dev/null || { echo "Not logged in. Run 'az login' first." >&2; exit 1; }
TENANT="${TENANT:-$(az account show --query tenantId -o tsv)}"
mkdir -p "$OUT_DIR"
BASE="$OUT_DIR/apim-config-$TENANT-$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/apim-cfg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Writes all items of a paged ARM list as a JSON array to $2, or {"error": "..."} on failure.
# Temp files (not --argjson) avoid the 128 KB per-argument limit on Linux.
arm_list() {
  local url="$1" out="$2"
  echo '[]' > "$out"
  while [ -n "$url" ]; do
    if ! az rest --method get --url "$url" -o json > "$WORK/page.json" 2> "$WORK/err.txt"; then
      jq -n --arg e "$(grep -m1 . "$WORK/err.txt" | sed 's/^ERROR: //' | cut -c1-300)" '{error: $e}' > "$out"
      return 0
    fi
    jq -s '.[0] + .[1].value' "$out" "$WORK/page.json" > "$WORK/acc.json" && mv "$WORK/acc.json" "$out"
    url="$(jq -r '.nextLink // empty' "$WORK/page.json")"
  done
}

# Resource Graph via REST (no CLI extension needed). The tenantId filter keeps only
# resources homed in the tenant, which excludes Lighthouse-delegated subscriptions.
log "Finding APIM instances in tenant $TENANT..."
QUERY="resources
| where type =~ 'microsoft.apimanagement/service' and tenantId =~ '$TENANT'
| join kind=leftouter (resourcecontainers | where type =~ 'microsoft.resources/subscriptions'
    | project subscriptionId, subscriptionName = name) on subscriptionId
| project id, name, subscriptionId, subscriptionName, resourceGroup, location, sku = tostring(sku.name)
| order by subscriptionName asc, name asc"
echo '[]' > "$WORK/instances.json"; SKIP=""
while :; do
  jq -cn --arg q "$QUERY" --arg s "$SKIP" \
    '{query: $q, options: ({"$top": 1000} + (if $s != "" then {"$skipToken": $s} else {} end))}' > "$WORK/body.json"
  az rest --method post --body "@$WORK/body.json" \
    --url "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01" \
    -o json > "$WORK/page.json"
  jq -s '.[0] + .[1].data' "$WORK/instances.json" "$WORK/page.json" > "$WORK/acc.json" \
    && mv "$WORK/acc.json" "$WORK/instances.json"
  SKIP="$(jq -r '."$skipToken" // empty' "$WORK/page.json")"
  [ -z "$SKIP" ] && break
done
COUNT="$(jq length "$WORK/instances.json")"
log "Found $COUNT APIM instance(s)."

echo '[]' > "$WORK/results.json"
i=0
while [ "$i" -lt "$COUNT" ]; do
  ID="$(jq -r ".[$i].id" "$WORK/instances.json")"
  log "  [$((i + 1))/$COUNT] $(jq -r ".[$i].name" "$WORK/instances.json")"
  arm_list "https://management.azure.com$ID/namedValues?api-version=$API" "$WORK/nv.json"
  arm_list "https://management.azure.com$ID/authorizationServers?api-version=$API" "$WORK/as.json"
  arm_list "https://management.azure.com$ID/openidConnectProviders?api-version=$API" "$WORK/op.json"
  jq --argjson i "$i" --argjson v "$VALUES" --slurpfile inst "$WORK/instances.json" \
     --slurpfile nv "$WORK/nv.json" --slurpfile as "$WORK/as.json" --slurpfile op "$WORK/op.json" '
    def compact: with_entries(select(.value != null and .value != []));
    def each(x; f): if (x | type) == "array" then [x[] | f | compact] else x end;
    . + [$inst[0][$i] + {
      namedValues: each($nv[0]; .properties as $p | {
        name: $p.displayName,
        type: (if $p.keyVault then "KeyVault" elif $p.secret then "Secret" else "Plain" end),
        keyVaultSecret: $p.keyVault.secretIdentifier,
        keyVaultIdentity: (if $p.keyVault then ($p.keyVault.identityClientId // "system-assigned") else null end),
        keyVaultStatus: $p.keyVault.lastStatus.code,
        tags: $p.tags,
        value: (if $v and ($p.secret | not) then $p.value else null end)
      }),
      oauth2AuthorizationServers: each($as[0]; .properties as $p | {
        name: $p.displayName,
        clientId: $p.clientId,
        grantTypes: $p.grantTypes,
        authorizationEndpoint: $p.authorizationEndpoint,
        tokenEndpoint: $p.tokenEndpoint,
        defaultScope: $p.defaultScope,
        clientAuthenticationMethod: $p.clientAuthenticationMethod,
        tokenBodyParameters: [$p.tokenBodyParameters[]? | if $v then "\(.name)=\(.value)" else .name end],
        useInTestConsole: $p.useInTestConsole,
        useInApiDocumentation: $p.useInApiDocumentation
      }),
      openIdConnectProviders: each($op[0]; .properties as $p | {
        name: $p.displayName,
        clientId: $p.clientId,
        metadataEndpoint: $p.metadataEndpoint,
        useInTestConsole: $p.useInTestConsole,
        useInApiDocumentation: $p.useInApiDocumentation
      })
    }]' "$WORK/results.json" > "$WORK/acc.json" && mv "$WORK/acc.json" "$WORK/results.json"
  i=$((i + 1))
done

jq --arg t "$TENANT" '{tenantId: $t, generatedUtc: (now | todate), apimInstances: .}' "$WORK/results.json" > "$BASE.json"

jq -r '
  def section(title; x; line):
    if (x | type) == "object" then "  \(title): ERROR \(x.error)"
    elif (x | length) == 0 then "  \(title): none"
    else "  \(title) (\(x | length)):", (x[] | "    - " + line) end;
  "Tenant: \(.tenantId)   Generated: \(.generatedUtc)   APIM instances: \(.apimInstances | length)",
  (.apimInstances[] |
    "",
    "=== \(.name)  [\(.sku), \(.location)]  sub: \(.subscriptionName // .subscriptionId)  rg: \(.resourceGroup)",
    section("Named values"; .namedValues;
      "\(.name)  [\(.type)]"
      + (if .keyVaultSecret then "  \(.keyVaultSecret)  identity: \(.keyVaultIdentity)  status: \(.keyVaultStatus // "n/a")" else "" end)
      + (if .value then "  = \(.value)" else "" end)),
    section("OAuth 2.0 authorization servers"; .oauth2AuthorizationServers;
      "\(.name)  clientId: \(.clientId // "-")  grants: \(.grantTypes // [] | join(","))"
      + "  token: \(.tokenEndpoint // "-")"
      + (if .defaultScope then "  scope: \(.defaultScope)" else "" end)
      + (if .tokenBodyParameters then "  bodyParams: \(.tokenBodyParameters | join(","))" else "" end)),
    section("OpenID Connect providers"; .openIdConnectProviders;
      "\(.name)  clientId: \(.clientId // "-")  metadata: \(.metadataEndpoint)"))
' "$BASE.json" | tee "$BASE.txt"

log "Wrote $BASE.json and $BASE.txt"
