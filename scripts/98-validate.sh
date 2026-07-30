#!/usr/bin/env bash
###############################################################################
# 98-validate.sh — Read-only network validation for all three scenarios.
#
# Asserts the *intended* network posture (public access disabled, private
# endpoints approved, DNS zones linked, subnet delegations, NSP profile/rules)
# and prints a PASS / FAIL / SKIP table. Makes NO changes — safe on a live lab.
#
# Usage:
#   ./scripts/98-validate.sh                 # every deployed scenario
#   ./scripts/98-validate.sh -s 3            # only Scenario 3
#   ./scripts/98-validate.sh -s 1 --suffix abcde
#   ./scripts/98-validate.sh -s 2 -g rg-foundry-agent-<suffix>
#
# Exit code is non-zero if any CRITICAL check FAILs. A scenario whose suffix
# file / resource group is absent is reported SKIP (not a failure).
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCENARIO="all"
OVERRIDE_SUFFIX=""
OVERRIDE_RG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--scenario) SCENARIO="$2"; shift 2 ;;
        --suffix)      OVERRIDE_SUFFIX="$2"; shift 2 ;;
        -g|--resource-group) OVERRIDE_RG="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "${BASH_SOURCE[0]}" | sed 's/^#//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Colours (fall back to empty if not a TTY)
if [[ -t 1 ]]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
    C_GRAY=$'\033[90m'; C_CYAN=$'\033[36m'; C_RST=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_YEL=""; C_GRAY=""; C_CYAN=""; C_RST=""
fi

CRITICAL_FAIL=0
declare -a R_SCN R_CHECK R_STATUS R_DETAIL

add_result() {  # scenario check status detail critical(0/1)
    R_SCN+=("$1"); R_CHECK+=("$2"); R_STATUS+=("$3"); R_DETAIL+=("$4")
    if [[ "$3" == "FAIL" && "${5:-0}" == "1" ]]; then CRITICAL_FAIL=1; fi
}

# Read-only az wrapper: echo trimmed stdout, empty string on any error.
az_q() {
    local out
    if out="$(az "$@" 2>/dev/null)"; then
        printf '%s' "$out" | tr -d '\r'
    else
        printf ''
    fi
}

rg_exists() { [[ "$(az_q group exists --name "$1")" == "true" ]]; }

read_suffix() {  # filename
    local p="$SCRIPT_DIR/$1"
    [[ -f "$p" ]] && tr -d '\r\n' < "$p" || printf ''
}

# ---------------------------------------------------------------------------
# Scenario 1 — Private Endpoint + VNet Integration
# ---------------------------------------------------------------------------
validate_s1() {
    local sfx rg
    sfx="${OVERRIDE_SUFFIX:-$(read_suffix .deploy-suffix)}"
    rg="${OVERRIDE_RG:-}"; [[ -z "$rg" && -n "$sfx" ]] && rg="rg-foundry-demo-$sfx"

    if [[ -z "$rg" ]] || ! rg_exists "$rg"; then
        add_result S1 "Deployment present" SKIP "no .deploy-suffix / resource group — not deployed"
        return
    fi
    local ai="foundry-demo-ai-$sfx" app="foundry-demo-app-$sfx" vnet="foundry-demo-vnet-$sfx"
    local zone="privatelink.cognitiveservices.azure.com"

    local pna; pna="$(az_q cognitiveservices account show -g "$rg" -n "$ai" --query properties.publicNetworkAccess -o tsv)"
    if [[ "$pna" == "Disabled" ]]; then add_result S1 "Foundry publicNetworkAccess" PASS "$pna"
    elif [[ -n "$pna" ]]; then add_result S1 "Foundry publicNetworkAccess" FAIL "$pna (expected Disabled)" 1
    else add_result S1 "Foundry publicNetworkAccess" SKIP "account $ai not found"; fi

    local pe; pe="$(az_q network private-endpoint list -g "$rg" --query "[].privateLinkServiceConnections[].privateLinkServiceConnectionState.status" -o tsv)"
    if grep -q Approved <<<"$pe"; then add_result S1 "Private endpoint approved" PASS "Approved"
    elif [[ -n "$pe" ]]; then add_result S1 "Private endpoint approved" FAIL "$pe" 1
    else add_result S1 "Private endpoint approved" FAIL "no private endpoint found" 1; fi

    local link; link="$(az_q network private-dns link vnet list -g "$rg" -z "$zone" --query "[].virtualNetwork.id" -o tsv)"
    if grep -q "$vnet" <<<"$link"; then add_result S1 "Private DNS zone linked to VNet" PASS "$zone"
    elif [[ -n "$link" ]]; then add_result S1 "Private DNS zone linked to VNet" WARN "linked to a different vnet"
    else add_result S1 "Private DNS zone linked to VNet" SKIP "$zone not found"; fi

    local arec; arec="$(az_q network private-dns record-set a list -g "$rg" -z "$zone" --query "[].aRecords[].ipv4Address" -o tsv)"
    if grep -Eq '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' <<<"$arec"; then
        add_result S1 "DNS A-record is private" PASS "$(head -n1 <<<"$arec")"
    elif [[ -n "$arec" ]]; then add_result S1 "DNS A-record is private" WARN "$arec"
    else add_result S1 "DNS A-record is private" SKIP "no A record yet"; fi

    local subnet; subnet="$(az_q webapp show -g "$rg" -n "$app" --query virtualNetworkSubnetId -o tsv)"
    if [[ -n "$subnet" ]]; then add_result S1 "App Service VNet integration" PASS "${subnet##*/}"
    else add_result S1 "App Service VNet integration" FAIL "not integrated" 1; fi

    local route; route="$(az_q webapp config show -g "$rg" -n "$app" --query vnetRouteAllEnabled -o tsv)"
    if [[ "$route" == "true" ]]; then add_result S1 "Route-all outbound enabled" PASS "true"
    elif [[ -n "$route" ]]; then add_result S1 "Route-all outbound enabled" WARN "$route"
    else add_result S1 "Route-all outbound enabled" SKIP "app not found"; fi
}

# ---------------------------------------------------------------------------
# Scenario 3 — Network Security Perimeter + Managed Identity
# ---------------------------------------------------------------------------
validate_s3() {
    local sfx rg
    sfx="${OVERRIDE_SUFFIX:-$(read_suffix .deploy-suffix)}"
    rg="${OVERRIDE_RG:-}"; [[ -z "$rg" && -n "$sfx" ]] && rg="rg-foundry-demo-$sfx"

    if [[ -z "$rg" ]] || ! rg_exists "$rg"; then
        add_result S3 "Deployment present" SKIP "no .deploy-suffix / resource group — not deployed"
        return
    fi
    local ai="foundry-demo-ai-$sfx" nspApp="foundry-demo-nsp-app-$sfx"
    local nsp="foundry-demo-nsp-$sfx" law="foundry-demo-law-$sfx"

    # NSP model: the Foundry endpoint DNS stays PUBLIC by design — access is gated at the
    # IDENTITY layer by the perimeter, not by the account switch. publicNetworkAccess=Enabled
    # is EXPECTED here (opposite of Scenario 1); the real control is the Enforced association.
    local pna; pna="$(az_q cognitiveservices account show -g "$rg" -n "$ai" --query properties.publicNetworkAccess -o tsv)"
    if [[ "$pna" == "Enabled" ]]; then add_result S3 "Foundry publicNetworkAccess" PASS "Enabled (DNS stays public; NSP gates at identity layer)"
    elif [[ "$pna" == "Disabled" ]]; then add_result S3 "Foundry publicNetworkAccess" WARN "Disabled (NSP scenario normally keeps this Enabled + Enforced perimeter)"
    else add_result S3 "Foundry publicNetworkAccess" SKIP "account $ai not found — NSP scenario may not be applied"; fi

    # Discover the NSP, association, and access rules WITHOUT the preview 'nsp' az extension —
    # using generic 'az resource' + 'az rest' so this works on a stock az install.
    local nspApi="2023-08-01-preview"
    local nspId; nspId="$(az_q resource list -g "$rg" --resource-type "Microsoft.Network/networkSecurityPerimeters" --query "[?name=='$nsp'].id | [0]" -o tsv)"
    if [[ -n "$nspId" ]]; then
        add_result S3 "Network Security Perimeter exists" PASS "$nsp"

        local mode; mode="$(az_q rest --method get --url "https://management.azure.com${nspId}/resourceAssociations?api-version=${nspApi}" --query "value[0].properties.accessMode" -o tsv)"
        if grep -q Enforced <<<"$mode"; then add_result S3 "NSP access mode" PASS "Enforced"
        elif grep -q Learning <<<"$mode"; then add_result S3 "NSP access mode" WARN "Learning (not yet enforcing)"
        elif [[ -n "$mode" ]]; then add_result S3 "NSP access mode" WARN "$mode"
        else add_result S3 "NSP association" FAIL "no association found" 1; fi

        local rules; rules="$(az_q rest --method get --url "https://management.azure.com${nspId}/profiles/foundry-demo-nsp-profile/accessRules?api-version=${nspApi}" --query "value[].name" -o tsv)"
        if [[ -n "$rules" ]]; then add_result S3 "NSP inbound access rule(s)" PASS "$(grep -c . <<<"$rules") rule(s)"
        else add_result S3 "NSP inbound access rule(s)" WARN "no rules returned"; fi
    else
        add_result S3 "Network Security Perimeter exists" FAIL "NSP $nsp not found" 1
    fi

    local subnet; subnet="$(az_q webapp show -g "$rg" -n "$nspApp" --query virtualNetworkSubnetId -o tsv)"
    if [[ -z "$subnet" ]]; then
        local exists; exists="$(az_q webapp show -g "$rg" -n "$nspApp" --query name -o tsv)"
        if [[ -n "$exists" ]]; then add_result S3 "NSP app has NO VNet integration" PASS "identity-only path (correct)"
        else add_result S3 "NSP app has NO VNet integration" SKIP "$nspApp not found"; fi
    else add_result S3 "NSP app has NO VNet integration" FAIL "unexpectedly integrated: $subnet"; fi

    local lawId; lawId="$(az_q monitor log-analytics workspace show -g "$rg" -n "$law" --query id -o tsv)"
    if [[ -n "$lawId" ]]; then
        add_result S3 "Log Analytics workspace" PASS "$law"
        if [[ -n "$nspId" ]]; then
            local diag; diag="$(az_q monitor diagnostic-settings list --resource "$nspId" --query "[?name=='nsp-access-logs'] | length(@)" -o tsv)"
            if [[ "$diag" == "1" ]]; then add_result S3 "Diagnostic setting nsp-access-logs" PASS "NSPAccessLogs wired"
            else add_result S3 "Diagnostic setting nsp-access-logs" WARN "not found on NSP"; fi
        fi
    else add_result S3 "Log Analytics workspace" SKIP "$law not found"; fi
}

# ---------------------------------------------------------------------------
# Scenario 2 — Private Agent + VNet Injection (discover resources by listing)
# ---------------------------------------------------------------------------
validate_s2() {
    local sfx rg
    sfx="${OVERRIDE_SUFFIX:-$(read_suffix .deploy-suffix-agent)}"
    rg="${OVERRIDE_RG:-}"; [[ -z "$rg" && -n "$sfx" ]] && rg="rg-foundry-agent-$sfx"

    if [[ -z "$rg" ]] || ! rg_exists "$rg"; then
        add_result S2 "Deployment present" SKIP "no .deploy-suffix-agent / resource group — not deployed"
        return
    fi

    local stg; stg="$(az_q storage account list -g "$rg" --query "[].publicNetworkAccess" -o tsv)"
    if [[ -n "$stg" ]] && ! grep -q Enabled <<<"$stg"; then add_result S2 "Storage publicNetworkAccess" PASS "Disabled"
    elif [[ -n "$stg" ]]; then add_result S2 "Storage publicNetworkAccess" FAIL "$stg" 1
    else add_result S2 "Storage publicNetworkAccess" SKIP "no storage account found"; fi

    local cos; cos="$(az_q cosmosdb list -g "$rg" --query "[].publicNetworkAccess" -o tsv)"
    if [[ -n "$cos" ]] && ! grep -q Enabled <<<"$cos"; then add_result S2 "Cosmos DB publicNetworkAccess" PASS "Disabled"
    elif [[ -n "$cos" ]]; then add_result S2 "Cosmos DB publicNetworkAccess" FAIL "$cos" 1
    else add_result S2 "Cosmos DB publicNetworkAccess" SKIP "no Cosmos account found"; fi

    local srch; srch="$(az_q search service list -g "$rg" --query "[].publicNetworkAccess" -o tsv)"
    if grep -qi disabled <<<"$srch"; then add_result S2 "AI Search publicNetworkAccess" PASS "disabled"
    elif [[ -n "$srch" ]]; then add_result S2 "AI Search publicNetworkAccess" FAIL "$srch" 1
    else add_result S2 "AI Search publicNetworkAccess" SKIP "no Search service found"; fi

    local aipna; aipna="$(az_q cognitiveservices account list -g "$rg" --query "[].properties.publicNetworkAccess" -o tsv)"
    if [[ -n "$aipna" ]] && ! grep -q Enabled <<<"$aipna"; then add_result S2 "Foundry publicNetworkAccess" PASS "Disabled"
    elif [[ -n "$aipna" ]]; then add_result S2 "Foundry publicNetworkAccess" FAIL "$aipna" 1
    else add_result S2 "Foundry publicNetworkAccess" SKIP "no Foundry account found"; fi

    local pe; pe="$(az_q network private-endpoint list -g "$rg" --query "[].privateLinkServiceConnections[].privateLinkServiceConnectionState.status" -o tsv)"
    if [[ -n "$pe" ]]; then
        local bad; bad="$(grep -v Approved <<<"$pe" || true)"
        if [[ -z "$bad" ]]; then add_result S2 "Private endpoints approved" PASS "$(grep -c . <<<"$pe") endpoint(s) Approved"
        else add_result S2 "Private endpoints approved" FAIL "$(tr '\n' ',' <<<"$bad")" 1; fi
    else add_result S2 "Private endpoints approved" FAIL "no private endpoints found" 1; fi

    local expected=(
        "privatelink.services.ai.azure.com" "privatelink.openai.azure.com"
        "privatelink.cognitiveservices.azure.com" "privatelink.search.windows.net"
        "privatelink.blob.core.windows.net" "privatelink.documents.azure.com"
    )
    local zones; zones="$(az_q network private-dns zone list -g "$rg" --query "[].name" -o tsv)"
    local missing=""
    for z in "${expected[@]}"; do grep -qx "$z" <<<"$zones" || missing+="$z "; done
    if [[ -z "$missing" && -n "$zones" ]]; then add_result S2 "Six private DNS zones present" PASS "6/6 core zones"
    elif [[ -n "$zones" ]]; then add_result S2 "Six private DNS zones present" FAIL "missing: $missing" 1
    else add_result S2 "Six private DNS zones present" SKIP "no private DNS zones found"; fi

    local vnet; vnet="$(az_q network vnet list -g "$rg" --query "[0].name" -o tsv)"
    if [[ -n "$vnet" ]]; then
        local linkedAll=1
        for z in "privatelink.blob.core.windows.net" "privatelink.search.windows.net" "privatelink.documents.azure.com"; do
            if grep -qx "$z" <<<"$zones"; then
                local l; l="$(az_q network private-dns link vnet list -g "$rg" -z "$z" --query "[].virtualNetwork.id" -o tsv)"
                grep -q "$vnet" <<<"$l" || linkedAll=0
            fi
        done
        if [[ "$linkedAll" == "1" ]]; then add_result S2 "DNS zones VNet-linked" PASS "linked to $vnet"
        else add_result S2 "DNS zones VNet-linked" FAIL "one or more zones not linked to the agent VNet" 1; fi

        local ad; ad="$(az_q network vnet subnet show -g "$rg" --vnet-name "$vnet" -n agent-subnet --query "delegations[].serviceName" -o tsv)"
        if grep -q "Microsoft.App/environments" <<<"$ad"; then add_result S2 "agent-subnet delegation" PASS "Microsoft.App/environments"
        elif [[ -n "$ad" ]]; then add_result S2 "agent-subnet delegation" WARN "$ad"
        else add_result S2 "agent-subnet delegation" SKIP "agent-subnet not found"; fi

        local pd; pd="$(az_q network vnet subnet show -g "$rg" --vnet-name "$vnet" -n app-subnet --query "delegations[].serviceName" -o tsv)"
        if grep -q "Microsoft.Web/serverFarms" <<<"$pd"; then add_result S2 "app-subnet delegation" PASS "Microsoft.Web/serverFarms"
        elif [[ -n "$pd" ]]; then add_result S2 "app-subnet delegation" WARN "$pd"
        else add_result S2 "app-subnet delegation" SKIP "app-subnet not found"; fi
    else add_result S2 "VNet present" FAIL "no VNet found in RG" 1; fi

    local web; web="$(az_q webapp list -g "$rg" --query "[0].name" -o tsv)"
    if [[ -n "$web" ]]; then
        local subnet; subnet="$(az_q webapp show -g "$rg" -n "$web" --query virtualNetworkSubnetId -o tsv)"
        if grep -q "/subnets/app-subnet" <<<"$subnet"; then add_result S2 "Test WebApp VNet-integrated" PASS "app-subnet"
        elif [[ -n "$subnet" ]]; then add_result S2 "Test WebApp VNet-integrated" WARN "${subnet##*/}"
        else add_result S2 "Test WebApp VNet-integrated" FAIL "not integrated" 1; fi
    else add_result S2 "Test WebApp VNet-integrated" SKIP "no WebApp found"; fi
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
echo ""
echo "${C_CYAN}=== Foundry Network Security — Validation ===${C_RST}"

ACCT="$(az_q account show --query name -o tsv)"
if [[ -z "$ACCT" ]]; then
    echo "${C_RED}Not logged in to Azure. Run: az login${C_RST}"; exit 2
fi
echo "${C_GRAY}Subscription: $ACCT${C_RST}"

case "$SCENARIO" in
    1) validate_s1 ;;
    2) validate_s2 ;;
    3) validate_s3 ;;
    all) validate_s1; validate_s2; validate_s3 ;;
    *) echo "Invalid -s value: $SCENARIO (use 1|2|3|all)" >&2; exit 2 ;;
esac

echo ""
printf "%-4s %-38s %-6s %s\n" "Scn" "Check" "Status" "Detail"
printf '%.0s-' {1..90}; echo ""
pass=0; fail=0; warn=0; skip=0
for i in "${!R_SCN[@]}"; do
    st="${R_STATUS[$i]}"
    case "$st" in
        PASS) c="$C_GREEN"; ((pass++)) ;;
        FAIL) c="$C_RED"; ((fail++)) ;;
        WARN) c="$C_YEL"; ((warn++)) ;;
        *)    c="$C_GRAY"; ((skip++)) ;;
    esac
    printf "%b%-4s %-38s %-6s %s%b\n" "$c" "${R_SCN[$i]}" "${R_CHECK[$i]}" "$st" "${R_DETAIL[$i]}" "$C_RST"
done

echo ""
echo "Summary: ${pass} PASS, ${fail} FAIL, ${warn} WARN, ${skip} SKIP"

if [[ "$CRITICAL_FAIL" == "1" ]]; then
    echo "${C_RED}CRITICAL network check failed — see FAIL rows above.${C_RST}"
    exit 1
fi
exit 0
