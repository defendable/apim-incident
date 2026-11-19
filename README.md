# apim-incident

Azure API Management (APIM) incident tooling: scripts to inventory APIM instances, their logging, and their authentication-related configuration.

Both scripts are read-only: they make no changes to Azure resources. They require the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (signed in with `az login`) and [`jq`](https://jqlang.github.io/jq/). Azure Cloud Shell has both. `apim-diagnostics.sh` also installs the `resource-graph` CLI extension if it's missing.

## apim-diagnostics.sh

Lists every APIM instance the signed-in account can see, grouped by tenant. This covers all subscriptions the account can access, including tenants delegated through Azure Lighthouse. For each instance it shows the diagnostic settings: which log categories and metrics are enabled and where they are sent (Log Analytics workspace, storage account, Event Hub or partner solution).

**Use case:** check which APIM instances send logs to a workspace (for example Microsoft Sentinel) and which have no logging. Use this to confirm visibility before or during an investigation, or to review logging coverage across many subscriptions or tenants.

```bash
./apim-diagnostics.sh [-o OUTPUT_DIR] [-p PARALLELISM]
```

Writes `apim-instances.json`, `apim-diagnostics.json`, `apim-diagnostics.csv` and `apim-diagnostics.txt` to `./output` by default.

## apim-config-inventory.sh

Lists the **Named values** and **OAuth 2.0 + OpenID Connect** configuration (authorization servers and OpenID Connect providers) for all APIM instances in one tenant. Resources delegated through Lighthouse are excluded. Reader access is enough.

Secret values, Key Vault secrets and OAuth client secrets are never retrieved. By default, values of plain named values and OAuth token body parameters are also left out; `-v` includes them.

**Use case:** get an overview of the credentials, Key Vault references and identity provider integrations stored in APIM, to scope exposure and decide which secrets to rotate. Anyone with Reader access to the tenant can run it, for example in Cloud Shell, and share the output with whoever is handling the investigation.

```bash
./apim-config-inventory.sh [-t TENANT_ID] [-o OUTPUT_DIR] [-v]
```

Writes `apim-config-<tenant>-<timestamp>.json` and `.txt` to the current directory by default.

## Output

Script output describes your Azure environment, including resource names, endpoints, client IDs and Key Vault references. Treat it as sensitive and don't commit it. `output/` is ignored by git, so to keep `apim-config-inventory.sh` results out of the repo, run it with `-o output`.
