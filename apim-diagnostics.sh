#!/usr/bin/env bash
#
# Inventory all API Management instances visible to the signed-in az CLI account
# (directly or via Azure Lighthouse), grouped by tenant, and list the diagnostic
# settings on each instance: which logs/metrics are sent and to which destination.
#
# Requirements: az CLI (logged in), jq. The resource-graph extension is installed if missing.
#
# Usage: ./apim-diagnostics.sh [-o OUTPUT_DIR] [-p PARALLELISM]
#   -o  Output directory (default: ./output)
#   -p  Parallel diagnostic-settings requests (default: 8)
#
# Outputs (in OUTPUT_DIR):
#   apim-instances.json      APIM inventory with tenant names
#   apim-diagnostics.json    Inventory + raw-ish diagnostic settings per instance
#   apim-diagnostics.csv     One row per instance x diagnostic setting
#   apim-diagnostics.txt     Human-readable report (also printed to stdout)

set -euo pipefail

OUT_DIR="./output"
PARALLEL=8
DIAG_API_VERSION="2021-05-01-preview"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while getopts ":o:p:h" opt; do
  case "$opt" in
    o) OUT_DIR="$OPTARG" ;;
    p) PARALLEL="$OPTARG" ;;
    *) usage ;;
  esac
done

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

for cmd in az jq; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
az account show -o none 2>/dev/null || { echo "Not logged in. Run 'az login' first." >&2; exit 1; }
az extension show -n resource-graph -o none 2>/dev/null \
  || az extension add -n resource-graph -y --only-show-errors

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/apim-diag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Runs a Resource Graph query, following skip tokens, and writes a JSON array to $2.
arg_query() {
  local query="$1" out="$2" token="" page=0
  echo '[]' > "$out"
  while :; do
    page=$((page + 1))
    if [ -n "$token" ]; then
      az graph query -q "$query" --first 1000 --skip-token "$token" -o json > "$WORK/page.json"
    else
      az graph query -q "$query" --first 1000 -o json > "$WORK/page.json"
    fi
    jq -s '.[0] + .[1].data' "$out" "$WORK/page.json" > "$WORK/merged.json" && mv "$WORK/merged.json" "$out"
    token="$(jq -r '.skip_token // empty' "$WORK/page.json")"
    [ -z "$token" ] && break
  done
}

MANAGING_TENANT="$(az account show --query tenantId -o tsv)"
log "Signed in to tenant $MANAGING_TENANT"

# --- Subscription and tenant name lookup ------------------------------------
log "Listing subscriptions..."
az account list --all -o json > "$WORK/subs.json"
# subscriptionId -> {name, tenantId}
jq 'map({(.id): {name, tenantId: (.homeTenantId // .tenantId)}}) | add // {}' \
  "$WORK/subs.json" > "$WORK/submap.json"

log "Resolving tenant names from Lighthouse registrations..."
arg_query "managedservicesresources
  | where type =~ 'microsoft.managedservices/registrationassignments'
  | extend d = properties.registrationDefinition.properties
  | where tostring(d.managedByTenantId) == '$MANAGING_TENANT'
  | summarize name = take_any(tostring(d.manageeTenantName)) by tenantId = tostring(d.manageeTenantId)" \
  "$WORK/lh-tenants.json"

# Lighthouse names first, then display names for tenants the user is a direct member of.
jq -s '
  (.[0] | map(select(.name != "") | {(.tenantId): .name}) | add // {}) as $lh
  | (.[1] | map(select(.tenantDisplayName != null and .tenantDisplayName != "")
              | {(.tenantId): .tenantDisplayName}) | add // {}) as $direct
  | $direct + $lh' "$WORK/lh-tenants.json" "$WORK/subs.json" > "$WORK/tenantmap.json"

# --- APIM inventory ---------------------------------------------------------
log "Querying APIM instances via Resource Graph..."
arg_query "resources
  | where type =~ 'microsoft.apimanagement/service'
  | project id, name, tenantId, subscriptionId, resourceGroup, location,
            sku = tostring(sku.name), capacity = toint(sku.capacity),
            vnetType = tostring(properties.virtualNetworkType),
            gatewayUrl = tostring(properties.gatewayUrl),
            provisioningState = tostring(properties.provisioningState)" \
  "$WORK/apim-raw.json"

APIM_COUNT="$(jq length "$WORK/apim-raw.json")"
log "Found $APIM_COUNT APIM instance(s)."

# Fall back to Microsoft Graph for any tenant (APIM owner) still without a name.
jq -r --slurpfile t "$WORK/tenantmap.json" \
  '[.[].tenantId] | unique[] | select($t[0][.] == null)' "$WORK/apim-raw.json" |
while read -r tid; do
  [ -z "$tid" ] && continue
  name="$(az rest --method get \
    --url "https://graph.microsoft.com/v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='$tid')" \
    --query displayName -o tsv 2>/dev/null || true)"
  if [ -n "$name" ]; then
    jq --arg k "$tid" --arg v "$name" '. + {($k): $v}' "$WORK/tenantmap.json" > "$WORK/tm.tmp" \
      && mv "$WORK/tm.tmp" "$WORK/tenantmap.json"
  fi
done

jq --slurpfile t "$WORK/tenantmap.json" --slurpfile s "$WORK/submap.json" '
  map(. + {
    tenantName: ($t[0][.tenantId] // .tenantId),
    subscriptionName: ($s[0][.subscriptionId].name // .subscriptionId)
  }) | sort_by((.tenantName | ascii_downcase), .name)' \
  "$WORK/apim-raw.json" > "$OUT_DIR/apim-instances.json"

# --- Diagnostic settings ----------------------------------------------------
log "Fetching diagnostic settings (parallelism: $PARALLEL)..."
mkdir -p "$WORK/diag"
fetch_diag() {
  local out="$1" api="$2" idx="$3" rid="$4" err attempt=1
  while :; do
    if az rest --method get \
        --url "https://management.azure.com${rid}/providers/Microsoft.Insights/diagnosticSettings?api-version=${api}" \
        -o json > "$out/$idx.json" 2> "$out/$idx.err"; then
      rm -f "$out/$idx.err"
      return 0
    fi
    # Permission errors are permanent; anything else (throttling, dropped connections) is retried.
    if grep -q 'AuthorizationFailed' "$out/$idx.err" || [ "$attempt" -ge 4 ]; then
      break
    fi
    sleep $((attempt * 3))
    attempt=$((attempt + 1))
  done
  err="$(sed -n 's/^ERROR: (\([A-Za-z]\{1,\}\)).*/\1/p' "$out/$idx.err" | head -1)"
  [ -z "$err" ] && err="$(grep -m1 -v '^[[:space:]]*$' "$out/$idx.err" | sed 's/^ERROR: //' | cut -c1-200)"
  jq -n --arg e "${err:-RequestFailed}" '{error: $e, value: []}' > "$out/$idx.json"
}
export -f fetch_diag

# Zero-padded index keeps file glob order identical to the inventory order.
jq -j 'to_entries[] | "\(.key | tostring | ("00000" + .)[-5:])\u0000\(.value.id)\u0000"' "$OUT_DIR/apim-instances.json" \
  | xargs -0 -n 2 -P "$PARALLEL" bash -c 'fetch_diag "$@"' _ "$WORK/diag" "$DIAG_API_VERSION"

if [ "$APIM_COUNT" -gt 0 ]; then
  jq -s '.' "$WORK"/diag/*.json > "$WORK/diag-all.json"
else
  echo '[]' > "$WORK/diag-all.json"
fi

jq --slurpfile d "$WORK/diag-all.json" \
   --slurpfile s "$WORK/submap.json" \
   --slurpfile t "$WORK/tenantmap.json" '
  # Describes a destination resource ID: name, type, resource group, subscription, tenant.
  def describe($rid):
    if ($rid // "") == "" then null else
      ($rid | split("/")) as $p
      | ($p[2]) as $sub
      | {
          id: $rid,
          name: $p[8],
          resourceGroup: $p[4],
          subscriptionId: $sub,
          subscriptionName: ($s[0][$sub].name // $sub),
          tenantName: (($s[0][$sub].tenantId) as $tid
                       | if $tid then ($t[0][$tid] // $tid) else "unknown (subscription not visible)" end)
        }
    end;

  to_entries | map(
    .key as $k | .value as $apim
    | $d[0][$k] as $diag
    | $apim + {
        diagnosticsError: ($diag.error // null),
        diagnosticSettings: [
          ($diag.value // [])[] | .properties as $pr | {
            name,
            logs:    [$pr.logs[]?    | select(.enabled) | (.category // ("categoryGroup:" + .categoryGroup))],
            metrics: [$pr.metrics[]? | select(.enabled) | .category],
            logAnalytics: (describe($pr.workspaceId)
                           | if . then . + {destinationTable: ($pr.logAnalyticsDestinationType // "AzureDiagnostics")} else . end),
            storageAccount: describe($pr.storageAccountId),
            eventHub: (describe($pr.eventHubAuthorizationRuleId)
                       | if . then . + {namespace: (.id | split("/")[8]), eventHubName: ($pr.eventHubName // "(per category)")} else . end),
            partnerSolution: ($pr.marketplacePartnerId // null)
          }
        ]
      }
  )' "$OUT_DIR/apim-instances.json" > "$OUT_DIR/apim-diagnostics.json"

# CSV: one row per instance x diagnostic setting (instances without settings get one row).
jq -r '
  def dest($x): if $x then "\($x.name) [rg:\($x.resourceGroup) sub:\($x.subscriptionName) tenant:\($x.tenantName)]" else "" end;
  ["tenant","tenantId","apim","sku","location","subscription","resourceGroup",
   "diagnosticSetting","logs","metrics","logAnalyticsWorkspace","laDestinationTable",
   "storageAccount","eventHub","partnerSolution","status"],
  (.[] as $a
   | if ($a.diagnosticSettings | length) == 0 then
       [$a.tenantName,$a.tenantId,$a.name,$a.sku,$a.location,$a.subscriptionName,$a.resourceGroup,
        "","","","","","","","", (if $a.diagnosticsError then "ERROR: \($a.diagnosticsError)" else "NO DIAGNOSTIC SETTINGS" end)]
     else
       $a.diagnosticSettings[] as $ds
       | [$a.tenantName,$a.tenantId,$a.name,$a.sku,$a.location,$a.subscriptionName,$a.resourceGroup,
          $ds.name, ($ds.logs|join("; ")), ($ds.metrics|join("; ")),
          dest($ds.logAnalytics), ($ds.logAnalytics.destinationTable // ""),
          dest($ds.storageAccount),
          (if $ds.eventHub then "\($ds.eventHub.namespace)/\($ds.eventHub.eventHubName) [sub:\($ds.eventHub.subscriptionName) tenant:\($ds.eventHub.tenantName)]" else "" end),
          ($ds.partnerSolution // ""),
          (if ($ds.logs|length) == 0 then "NO LOGS ENABLED" else "OK" end)]
     end)
  | @csv' "$OUT_DIR/apim-diagnostics.json" > "$OUT_DIR/apim-diagnostics.csv"

# Human-readable report.
jq -r '
  def dest($x): "\($x.name)  (rg: \($x.resourceGroup), sub: \($x.subscriptionName), tenant: \($x.tenantName))";
  group_by(.tenantName | ascii_downcase)[]
  | "",
    "=== \(.[0].tenantName) (\(.[0].tenantId)) - \(length) APIM instance(s)",
    (.[] |
      "",
      "  \(.name)  [\(.sku), \(.location), sub: \(.subscriptionName), rg: \(.resourceGroup)]",
      (if .diagnosticsError then "    !! Could not read diagnostic settings: \(.diagnosticsError)"
       elif (.diagnosticSettings | length) == 0 then "    !! No diagnostic settings"
       else (.diagnosticSettings[] |
         "    - \(.name)",
         "        Logs:    \(if (.logs|length) > 0 then (.logs|join(", ")) else "(none enabled)" end)",
         "        Metrics: \(if (.metrics|length) > 0 then (.metrics|join(", ")) else "(none)" end)",
         (if .logAnalytics then "        -> Log Analytics: \(dest(.logAnalytics))  table mode: \(.logAnalytics.destinationTable)" else empty end),
         (if .storageAccount then "        -> Storage:       \(dest(.storageAccount))" else empty end),
         (if .eventHub then "        -> Event Hub:     \(.eventHub.namespace)/\(.eventHub.eventHubName)  (sub: \(.eventHub.subscriptionName), tenant: \(.eventHub.tenantName))" else empty end),
         (if .partnerSolution then "        -> Partner:       \(.partnerSolution)" else empty end))
       end))
' "$OUT_DIR/apim-diagnostics.json" > "$OUT_DIR/apim-diagnostics.txt"

jq -r '
  "",
  "Summary: \(length) APIM instance(s) across \(map(.tenantId)|unique|length) tenant(s)",
  "  with diagnostic settings sending logs: \(map(select(any(.diagnosticSettings[]; (.logs|length) > 0)))|length)",
  "  without any log-sending settings:    \(map(select(.diagnosticsError == null and all(.diagnosticSettings[]; (.logs|length) == 0)))|length)",
  "  unreadable (permission/other error):  \(map(select(.diagnosticsError != null))|length)"
' "$OUT_DIR/apim-diagnostics.json" >> "$OUT_DIR/apim-diagnostics.txt"

cat "$OUT_DIR/apim-diagnostics.txt"
log "Wrote $OUT_DIR/{apim-instances.json,apim-diagnostics.json,apim-diagnostics.csv,apim-diagnostics.txt}"
