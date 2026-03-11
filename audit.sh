#!/usr/bin/env bash
# =============================================================================
# aws_org_audit.sh  v1.0
#
# Zweck:
#   Liest alle Accounts einer AWS Organization aus dem Management-Account
#   und erstellt eine Markdown-Datei mit:
#     - Account-Übersicht (ID, Name, E-Mail, Status, OU-Pfad)
#     - Aktivierten AWS Control Tower Controls je Account (falls vorhanden)
#     - Angehängten Service Control Policies (SCPs) je Account
#
# Umgebung:
#   AWS CloudShell (Management-Account)
#   AWS CLI v2 + jq sind vorinstalliert
#
# Berechtigungen (mindestens erforderlich):
#   organizations:DescribeOrganization
#   organizations:ListAccounts
#   organizations:ListParents
#   organizations:DescribeOrganizationalUnit
#   organizations:ListPoliciesForTarget
#   organizations:DescribePolicy
#   controltower:ListEnabledControls          (optional, nur bei Control Tower)
#
# Verwendung:
#   chmod +x aws_org_audit.sh
#   ./aws_org_audit.sh
#   ./aws_org_audit.sh --output /pfad/zur/ausgabe.md
#   ./aws_org_audit.sh --region eu-central-1
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Konfiguration & Standardwerte
# -----------------------------------------------------------------------------
OUTPUT_FILE="aws_org_audit_$(date +%Y-%m-%d).md"
CT_REGION=""          # Wird automatisch erkannt; kann per --region überschrieben werden
TEMP_DIR=$(mktemp -d)
MGMT_ACCOUNT_ID=""
ORG_ID=""

trap 'rm -rf "${TEMP_DIR}"' EXIT

# -----------------------------------------------------------------------------
# Logging (kein ANSI / keine Farben)
# -----------------------------------------------------------------------------
log_info()  { echo "[INFO]  $(date +"%H:%M:%S")  $*"; }
log_warn()  { echo "[WARN]  $(date +"%H:%M:%S")  $*" >&2; }
log_error() { echo "[ERROR] $(date +"%H:%M:%S")  $*" >&2; }
log_step()  { echo ""; echo "==> $(date +"%H:%M:%S")  $*"; }

# -----------------------------------------------------------------------------
# Argumente
# -----------------------------------------------------------------------------
usage() {
    echo "Verwendung: $0 [--output <datei>] [--region <aws-region>] [--help]"
    echo ""
    echo "  --output <datei>    Pfad zur Ausgabe-Markdown-Datei"
    echo "                      Standard: aws_org_audit_YYYY-MM-DD.md"
    echo "  --region <region>   AWS-Region fuer Control Tower API"
    echo "                      Standard: wird automatisch erkannt"
    echo "  --help              Diese Hilfe anzeigen"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)   OUTPUT_FILE="$2"; shift 2 ;;
        --region)   CT_REGION="$2";   shift 2 ;;
        --help)     usage ;;
        *)          log_error "Unbekannte Option: $1"; usage ;;
    esac
done

# -----------------------------------------------------------------------------
# Hilfsfunktionen
# -----------------------------------------------------------------------------

# Liefert den vollständigen OU-Pfad (z.B. "Root / Security / Prod") fuer eine Account-ID
get_ou_path() {
    local target_id="$1"
    local path_parts=()
    local current_id="${target_id}"

    while true; do
        local parent_json
        parent_json=$(aws organizations list-parents \
            --child-id "${current_id}" \
            --output json 2>/dev/null || echo '{"Parents":[]}')

        local parent_id parent_type
        parent_id=$(echo "${parent_json}"   | jq -r '.Parents[0].Id   // ""')
        parent_type=$(echo "${parent_json}" | jq -r '.Parents[0].Type // ""')

        [[ -z "${parent_id}" ]] && break

        if [[ "${parent_type}" == "ROOT" ]]; then
            path_parts=("Root" "${path_parts[@]+"${path_parts[@]}"}")
            break
        elif [[ "${parent_type}" == "ORGANIZATIONAL_UNIT" ]]; then
            local ou_name
            ou_name=$(aws organizations describe-organizational-unit \
                --organizational-unit-id "${parent_id}" \
                --output json 2>/dev/null \
                | jq -r '.OrganizationalUnit.Name // "Unbekannt"')
            path_parts=("${ou_name}" "${path_parts[@]+"${path_parts[@]}"}")
            current_id="${parent_id}"
        else
            break
        fi
    done

    if [[ ${#path_parts[@]} -eq 0 ]]; then
        echo "Root"
    else
        local IFS=" / "
        echo "${path_parts[*]}"
    fi
}

# Liefert alle angehängten SCP-Namen fuer ein Target (Account-ID)
get_scps_for_target() {
    local target_id="$1"
    local scps=()

    local policies_json
    policies_json=$(aws organizations list-policies-for-target \
        --target-id "${target_id}" \
        --filter "SERVICE_CONTROL_POLICY" \
        --output json 2>/dev/null || echo '{"Policies":[]}')

    while IFS= read -r policy_id; do
        [[ -z "${policy_id}" ]] && continue
        local policy_name
        policy_name=$(aws organizations describe-policy \
            --policy-id "${policy_id}" \
            --output json 2>/dev/null \
            | jq -r '.Policy.PolicySummary.Name // "Unbekannt"')
        scps+=("${policy_name} (\`${policy_id}\`)")
    done < <(echo "${policies_json}" | jq -r '.Policies[].Id // empty')

    if [[ ${#scps[@]} -eq 0 ]]; then
        echo "_keine_"
    else
        local IFS=$'\n'
        echo "${scps[*]}"
    fi
}

# Erkennt die Control Tower Home Region automatisch
detect_ct_region() {
    local ct_region=""

    # Versuch 1: Aktuelle CLI-Region aus Umgebungsvariable oder Config
    ct_region="${AWS_DEFAULT_REGION:-}"

    if [[ -z "${ct_region}" ]]; then
        ct_region=$(aws configure get region 2>/dev/null || true)
    fi

    # Versuch 2: Fallback auf eu-central-1
    [[ -z "${ct_region}" ]] && ct_region="eu-central-1"

    echo "${ct_region}"
}

# Liefert aktivierte Control Tower Controls fuer einen Account
get_ct_controls_for_account() {
    local account_id="$1"
    local region="$2"
    local controls=()

    local target_arn="arn:aws:organizations::${MGMT_ACCOUNT_ID}:account/${ORG_ID}/${account_id}"

    local result
    result=$(aws controltower list-enabled-controls \
        --target-identifier "${target_arn}" \
        --region "${region}" \
        --output json 2>/dev/null || echo "ERROR")

    if [[ "${result}" == "ERROR" ]]; then
        echo "N/A"
        return
    fi

    while IFS= read -r control_arn; do
        [[ -z "${control_arn}" ]] && continue
        # Kurzname aus dem ARN extrahieren (letztes Segment)
        local short_name="${control_arn##*/}"
        controls+=("${short_name} (\`${control_arn}\`)")
    done < <(echo "${result}" | jq -r '.enabledControls[].controlIdentifier // empty')

    if [[ ${#controls[@]} -eq 0 ]]; then
        echo "_keine_"
    else
        local IFS=$'\n'
        echo "${controls[*]}"
    fi
}

# -----------------------------------------------------------------------------
# Hauptprogramm
# -----------------------------------------------------------------------------
main() {
    log_step "Starte AWS Organization Audit"

    # Organisation abrufen
    log_step "Organization-Metadaten abrufen"
    local org_json
    org_json=$(aws organizations describe-organization --output json)

    MGMT_ACCOUNT_ID=$(echo "${org_json}" | jq -r '.Organization.MasterAccountId')
    ORG_ID=$(echo "${org_json}"          | jq -r '.Organization.Id')
    local org_arn
    org_arn=$(echo "${org_json}"         | jq -r '.Organization.Arn')
    local feature_set
    feature_set=$(echo "${org_json}"     | jq -r '.Organization.FeatureSet')

    log_info "Management Account: ${MGMT_ACCOUNT_ID}"
    log_info "Organization ID:    ${ORG_ID}"
    log_info "Feature Set:        ${feature_set}"

    # Alle Accounts abrufen
    log_step "Accounts abrufen"
    local accounts_json="${TEMP_DIR}/accounts.json"
    aws organizations list-accounts --output json > "${accounts_json}"
    local account_count
    account_count=$(jq '.Accounts | length' "${accounts_json}")
    log_info "Gefundene Accounts: ${account_count}"

    # Control Tower Region ermitteln
    if [[ -z "${CT_REGION}" ]]; then
        log_step "Control Tower Region ermitteln"
        CT_REGION=$(detect_ct_region)
    fi
    log_info "Control Tower Region: ${CT_REGION}"

    # Control Tower verfuegbar?
    log_step "Control Tower Verfuegbarkeit pruefen"
    local ct_available=false
    if aws controltower list-landing-zones --region "${CT_REGION}" --output json &>/dev/null; then
        ct_available=true
        log_info "Control Tower: verfuegbar"
    else
        log_warn "Control Tower: nicht verfuegbar oder keine Berechtigung – Controls werden uebersprungen"
    fi

    # Alle Account-IDs in ein Array laden
    local account_ids=()
    while IFS= read -r id; do
        account_ids+=("${id}")
    done < <(jq -r '.Accounts[].Id' "${accounts_json}")

    # --------------------------------------------------------------------------
    # Markdown-Ausgabe aufbauen
    # --------------------------------------------------------------------------
    log_step "Markdown-Datei erstellen: ${OUTPUT_FILE}"

    # Header
    cat > "${OUTPUT_FILE}" <<EOF
# AWS Organization Audit

| | |
|---|---|
| **Erstellt am** | $(date +"%d.%m.%Y %H:%M:%S %Z") |
| **Management Account** | \`${MGMT_ACCOUNT_ID}\` |
| **Organization ID** | \`${ORG_ID}\` |
| **Organization ARN** | \`${org_arn}\` |
| **Feature Set** | ${feature_set} |
| **Anzahl Accounts** | ${account_count} |

---

## 1. Account-Uebersicht

| Account ID | Name | E-Mail | Status | OU-Pfad |
|---|---|---|---|---|
EOF

    # Tabellen-Zeilen
    for account_id in "${account_ids[@]}"; do
        local name email status ou_path
        name=$(jq -r --arg id "${account_id}"   '.Accounts[] | select(.Id == $id) | .Name'   "${accounts_json}")
        email=$(jq -r --arg id "${account_id}"  '.Accounts[] | select(.Id == $id) | .Email'  "${accounts_json}")
        status=$(jq -r --arg id "${account_id}" '.Accounts[] | select(.Id == $id) | .Status' "${accounts_json}")

        log_info "OU-Pfad ermitteln: ${account_id} (${name})"
        ou_path=$(get_ou_path "${account_id}")

        echo "| \`${account_id}\` | ${name} | ${email} | ${status} | ${ou_path} |" >> "${OUTPUT_FILE}"
    done

    # --------------------------------------------------------------------------
    # Abschnitt: SCPs
    # --------------------------------------------------------------------------
    cat >> "${OUTPUT_FILE}" <<'EOF'

---

## 2. Service Control Policies (SCPs) je Account

EOF

    for account_id in "${account_ids[@]}"; do
        local name scps
        name=$(jq -r --arg id "${account_id}" '.Accounts[] | select(.Id == $id) | .Name' "${accounts_json}")

        log_info "SCPs abrufen: ${account_id} (${name})"
        scps=$(get_scps_for_target "${account_id}")

        echo "### ${name} (\`${account_id}\`)" >> "${OUTPUT_FILE}"
        echo "" >> "${OUTPUT_FILE}"

        if [[ "${scps}" == "_keine_" ]]; then
            echo "_Keine SCPs direkt an diesem Account angehaengt._" >> "${OUTPUT_FILE}"
        else
            while IFS= read -r scp_line; do
                echo "- ${scp_line}" >> "${OUTPUT_FILE}"
            done <<< "${scps}"
        fi
        echo "" >> "${OUTPUT_FILE}"
    done

    # --------------------------------------------------------------------------
    # Abschnitt: Control Tower Controls
    # --------------------------------------------------------------------------
    cat >> "${OUTPUT_FILE}" <<'EOF'

---

## 3. Aktivierte Control Tower Controls je Account

EOF

    if [[ "${ct_available}" == false ]]; then
        echo "> **Hinweis:** Control Tower ist in dieser Organisation nicht verfuegbar oder die Berechtigung \`controltower:ListEnabledControls\` fehlt." >> "${OUTPUT_FILE}"
        echo "" >> "${OUTPUT_FILE}"
    else
        for account_id in "${account_ids[@]}"; do
            local name controls
            name=$(jq -r --arg id "${account_id}" '.Accounts[] | select(.Id == $id) | .Name' "${accounts_json}")

            log_info "Controls abrufen: ${account_id} (${name})"
            controls=$(get_ct_controls_for_account "${account_id}" "${CT_REGION}")

            echo "### ${name} (\`${account_id}\`)" >> "${OUTPUT_FILE}"
            echo "" >> "${OUTPUT_FILE}"

            case "${controls}" in
                "N/A")
                    echo "_Controls konnten fuer diesen Account nicht abgerufen werden._" >> "${OUTPUT_FILE}"
                    ;;
                "_keine_")
                    echo "_Keine Controls aktiviert._" >> "${OUTPUT_FILE}"
                    ;;
                *)
                    while IFS= read -r ctrl_line; do
                        echo "- ${ctrl_line}" >> "${OUTPUT_FILE}"
                    done <<< "${controls}"
                    ;;
            esac
            echo "" >> "${OUTPUT_FILE}"
        done
    fi

    # Fusszeile
    cat >> "${OUTPUT_FILE}" <<EOF

---

_Generiert von \`aws_org_audit.sh\` v1.0 am $(date +"%d.%m.%Y %H:%M:%S %Z")_
EOF

    log_step "Fertig"
    log_info "Ausgabedatei: ${OUTPUT_FILE}"
    log_info "Groesse:      $(wc -c < "${OUTPUT_FILE}") Bytes"
}

main "$@"
