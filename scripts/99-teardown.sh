#!/usr/bin/env bash
###############################################################################
# Teardown: Delete an Azure AI Foundry Demo lab
# Deletes the entire resource group (cascading every resource in it), then
# PURGES any soft-deleted Foundry (Cognitive Services) accounts so they don't
# linger (soft-deleted accounts still count against quota and block same-name
# redeploys).
#
# Scenarios:
#   nsp    -> rg-foundry-demo-<suffix>   (Scenarios 1 & 2, suffix file .deploy-suffix)
#   agent  -> rg-foundry-agent-<suffix>  (Scenario 3,      suffix file .deploy-suffix-agent)
#
# Usage:
#   ./99-teardown.sh                       # nsp lab, saved suffix, prompt to confirm
#   ./99-teardown.sh --scenario agent      # Scenario 3 lab
#   ./99-teardown.sh --suffix abc12        # override the suffix
#   ./99-teardown.sh --subscription <id>   # target a specific subscription
#   ./99-teardown.sh --yes                 # skip the confirmation prompt
#   ./99-teardown.sh --no-wait             # return immediately (async delete)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCENARIO="nsp"
SUFFIX=""
SUBSCRIPTION=""
ASSUME_YES="false"
NO_WAIT="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)     SCENARIO="$2"; shift 2 ;;
        --suffix)       SUFFIX="$2"; shift 2 ;;
        --subscription) SUBSCRIPTION="$2"; shift 2 ;;
        --yes|-y)       ASSUME_YES="true"; shift ;;
        --no-wait)      NO_WAIT="true"; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Scenario -> RG prefix + suffix file ---
if [[ "$SCENARIO" == "agent" ]]; then
    RG_PREFIX="rg-foundry-agent-"
    SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix-agent"
elif [[ "$SCENARIO" == "nsp" ]]; then
    RG_PREFIX="rg-foundry-demo-"
    SUFFIX_FILE="$SCRIPT_DIR/.deploy-suffix"
else
    echo "✗ Unknown --scenario '$SCENARIO' (expected 'nsp' or 'agent')." >&2
    exit 1
fi

# --- Resolve suffix ---
if [[ -z "$SUFFIX" ]]; then
    if [[ -f "$SUFFIX_FILE" ]]; then
        SUFFIX=$(cat "$SUFFIX_FILE")
    else
        echo "✗ No suffix found. Pass --suffix <value> ($SUFFIX_FILE is missing)." >&2
        exit 1
    fi
fi

RESOURCE_GROUP="$RG_PREFIX$SUFFIX"

# --- Optional subscription target ---
if [[ -n "$SUBSCRIPTION" ]]; then
    az account set --subscription "$SUBSCRIPTION"
fi
CURRENT_SUB=$(az account show --query name -o tsv)

# --- Verify the resource group exists ---
if [[ "$(az group exists --name "$RESOURCE_GROUP")" != "true" ]]; then
    echo "Resource group '$RESOURCE_GROUP' does not exist in subscription '$CURRENT_SUB'. Nothing to do."
    exit 0
fi

echo -e "\n▶ Resources to be deleted in '$RESOURCE_GROUP' (subscription: $CURRENT_SUB):"
az resource list --resource-group "$RESOURCE_GROUP" --query "[].{name:name,type:type}" -o table

# --- Capture Foundry (Cognitive Services) accounts so we can purge them after RG delete ---
FOUNDRY_ACCOUNTS=$(az resource list --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.CognitiveServices/accounts" \
    --query "[].{name:name,location:location}" -o json)

# --- Confirm ---
if [[ "$ASSUME_YES" != "true" ]]; then
    echo ""
    read -r -p "This will PERMANENTLY delete resource group '$RESOURCE_GROUP'. Type the suffix ('$SUFFIX') to confirm: " REPLY
    if [[ "$REPLY" != "$SUFFIX" ]]; then
        echo "Confirmation did not match. Aborting."
        exit 1
    fi
fi

# --- Delete ---
echo -e "\n▶ Deleting resource group: $RESOURCE_GROUP"
if [[ "$NO_WAIT" == "true" ]]; then
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
    echo "  ✓ Deletion started (running asynchronously)."
    if [[ "$FOUNDRY_ACCOUNTS" != "[]" ]]; then
        echo "  ⚠ Soft-deleted Foundry accounts were NOT purged (async delete). Re-run without --no-wait or purge manually with 'az cognitiveservices account purge'."
    fi
else
    az group delete --name "$RESOURCE_GROUP" --yes
    echo "  ✓ Resource group deleted."

    # --- Purge soft-deleted Foundry accounts (otherwise they linger + block redeploy) ---
    echo "$FOUNDRY_ACCOUNTS" | jq -c '.[]' | while read -r acct; do
        NAME=$(echo "$acct" | jq -r '.name')
        LOC=$(echo "$acct" | jq -r '.location')
        echo -e "\n▶ Purging soft-deleted Foundry account: $NAME ($LOC)"
        if az cognitiveservices account purge --name "$NAME" --resource-group "$RESOURCE_GROUP" --location "$LOC" --output none 2>/dev/null; then
            echo "  ✓ Purged $NAME"
        else
            echo "  ⚠ Could not purge $NAME (may already be gone)."
        fi
    done
fi

# --- Clear saved suffix so the next deploy generates a fresh one ---
if [[ -f "$SUFFIX_FILE" && "$SUFFIX" == "$(cat "$SUFFIX_FILE")" ]]; then
    rm -f "$SUFFIX_FILE"
    echo "  ✓ Cleared $SUFFIX_FILE"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Teardown complete for suffix: $SUFFIX (scenario: $SCENARIO)"
echo "════════════════════════════════════════════════════════════════"
