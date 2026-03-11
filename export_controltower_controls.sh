#!/usr/bin/env bash
# =============================================================================
# export_controltower_controls.sh
#
# Liest alle aktivierten Controls aus AWS Control Tower aus und schreibt
# den vollständigen OU-Pfad sowie den lesbaren Control-Namen in eine
# Markdown-Tabelle.
#
# Voraussetzungen:
#   - AWS CLI v2 installiert und konfiguriert
#   - Berechtigungen:
#       controltower:ListEnabledControls
#       controltower:GetControl
#       organizations:DescribeOrganizationalUnit
#       organizations:ListParents
#       organizations:ListRoots
#   - Läuft in der AWS CloudShell (Region wird automatisch erkannt)
#
# Ausgabe: controltower_enabled_controls.md
# =============================================================================

set -euo pipefail

# --- Konfiguration -----------------------------------------------------------
OUTPUT_FILE="controltower_enabled_controls.md"
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# Region aus CloudShell-Umgebung oder Fallback
REGION="${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo 'eu-central-1')}"

# Farben für Terminal-Ausgabe
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Caches (Assoziative Arrays) für OU-Pfade und Control-Namen
declare -A OU_PATH_CACHE
declare -A CONTROL_NAME_CACHE

# --- Hilfsfunktionen ---------------------------------------------------------
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Voraussetzungen prüfen --------------------------------------------------
check_prerequisites() {
    log_info "Prüfe Voraussetzungen..."

    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI nicht gefunden. Bitte installieren."
        exit 1
    fi
    AWS_CLI_VERSION=$(aws --version 2>&1 | awk '{print $1}')
    log_ok "AWS CLI gefunden: ${AWS_CLI_VERSION}"

    if ! command -v jq &>/dev/null; then
        log_warn "jq nicht gefunden – Installation wird versucht..."
        sudo yum install -y jq -q 2>/dev/null \
            || sudo apt-get install -y jq -q 2>/dev/null \
            || { log_error "jq konnte nicht installiert werden."; exit 1; }
        log_ok "jq erfolgreich installiert."
    else
        log_ok "jq gefunden: $(jq --version)"
    fi

    CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
        log_error "AWS-Authentifizierung fehlgeschlagen: ${CALLER_IDENTITY}"
        exit 1
    }
    ACCOUNT_ID=$(echo "${CALLER_IDENTITY}" | jq -r '.Account')
    CALLER_ARN=$(echo "${CALLER_IDENTITY}" | jq -r '.Arn')
    log_ok "Authentifiziert als: ${CALLER_ARN} (Account: ${ACCOUNT_ID})"
    log_info "Region: ${REGION}"
}

# --- Alle aktivierten Controls auslesen (mit Pagination) ---------------------
fetch_enabled_controls() {
    log_info "Lese aktivierte Controls aus Control Tower..."

    ALL_CONTROLS=()
    NEXT_TOKEN=""
    PAGE=1

    while true; do
        log_info "  Seite ${PAGE} wird abgerufen..."

        if [[ -z "${NEXT_TOKEN}" ]]; then
            RESPONSE=$(aws controltower list-enabled-controls \
                --region "${REGION}" \
                --output json 2>&1) || {
                log_error "Fehler beim Abruf: ${RESPONSE}"; exit 1
            }
        else
            RESPONSE=$(aws controltower list-enabled-controls \
                --region "${REGION}" \
                --next-token "${NEXT_TOKEN}" \
                --output json 2>&1) || {
                log_error "Fehler beim Abruf: ${RESPONSE}"; exit 1
            }
        fi

        mapfile -t PAGE_CONTROLS < <(echo "${RESPONSE}" | jq -c '.enabledControls[]')
        ALL_CONTROLS+=("${PAGE_CONTROLS[@]+"${PAGE_CONTROLS[@]}"}")

        NEXT_TOKEN=$(echo "${RESPONSE}" | jq -r '.nextToken // empty')
        [[ -z "${NEXT_TOKEN}" ]] && break
        PAGE=$((PAGE + 1))
    done

    TOTAL_COUNT=${#ALL_CONTROLS[@]}
    log_ok "Insgesamt ${TOTAL_COUNT} aktivierte Controls gefunden."
}

# --- OU-ID aus ARN extrahieren -----------------------------------------------
# Eingabe:  arn:aws:organizations::123456789012:ou/o-abc123/ou-def456-ghi789
# Ausgabe:  ou-def456-ghi789
extract_ou_id_from_arn() {
    local arn="$1"
    echo "${arn##*/}"
}

# --- Vollständigen OU-Pfad ermitteln (mit Cache) ------------------------------
# Traversiert rekursiv von der OU bis zur Root und baut den Pfad auf.
# Beispielausgabe: Root / Security / Production
get_ou_full_path() {
    local target_arn="$1"

    # Cache-Treffer?
    if [[ -n "${OU_PATH_CACHE[$target_arn]+_}" ]]; then
        echo "${OU_PATH_CACHE[$target_arn]}"
        return
    fi

    # Ist das Ziel ein Root?
    if [[ "${target_arn}" == *":root/"* ]]; then
        OU_PATH_CACHE["${target_arn}"]="Root"
        echo "Root"
        return
    fi

    # Ist das Ziel ein Account?
    if [[ "${target_arn}" == *":account/"* ]]; then
        local account_id
        account_id=$(echo "${target_arn}" | grep -oP '\d{12}$' || echo "unknown")
        local path="Account (${account_id})"
        OU_PATH_CACHE["${target_arn}"]="${path}"
        echo "${path}"
        return
    fi

    # OU-ID extrahieren
    local ou_id
    ou_id=$(extract_ou_id_from_arn "${target_arn}")

    # OU-Name abrufen
    local ou_name
    ou_name=$(aws organizations describe-organizational-unit \
        --organizational-unit-id "${ou_id}" \
        --query 'OrganizationalUnit.Name' \
        --output text 2>/dev/null || echo "${ou_id}")

    # Elternteil abrufen
    local parent_json
    parent_json=$(aws organizations list-parents \
        --child-id "${ou_id}" \
        --output json 2>/dev/null || echo '{"Parents":[]}')

    local parent_type parent_id
    parent_type=$(echo "${parent_json}" | jq -r '.Parents[0].Type // "UNKNOWN"')
    parent_id=$(echo "${parent_json}" | jq -r '.Parents[0].Id // ""')

    local parent_path
    if [[ "${parent_type}" == "ROOT" ]]; then
        parent_path="Root"
    elif [[ "${parent_type}" == "ORGANIZATIONAL_UNIT" ]]; then
        # Eltern-ARN rekonstruieren für rekursiven Aufruf
        local org_id account_part
        org_id=$(echo "${target_arn}" | grep -oP 'o-[a-z0-9]+' | head -1)
        account_part=$(echo "${target_arn}" | grep -oP '::\d+:' | tr -d ':')
        local parent_arn="arn:aws:organizations::${account_part}:ou/${org_id}/${parent_id}"
        parent_path=$(get_ou_full_path "${parent_arn}")
    else
        parent_path="?"
    fi

    local full_path="${parent_path} / ${ou_name}"
    OU_PATH_CACHE["${target_arn}"]="${full_path}"
    echo "${full_path}"
}

# --- Lesbaren Control-Namen abrufen (mit Cache) ------------------------------
# Nutzt controltower:GetControl → .control.displayName
# Fallback: technischer Name aus ARN
get_control_display_name() {
    local control_arn="$1"

    # Cache-Treffer?
    if [[ -n "${CONTROL_NAME_CACHE[$control_arn]+_}" ]]; then
        echo "${CONTROL_NAME_CACHE[$control_arn]}"
        return
    fi

    local display_name
    display_name=$(aws controltower get-control \
        --control-identifier "${control_arn}" \
        --region "${REGION}" \
        --query 'control.displayName' \
        --output text 2>/dev/null || echo "")

    # Fallback: technischer Name aus ARN
    if [[ -z "${display_name}" || "${display_name}" == "None" ]]; then
        display_name="${control_arn##*/}"
    fi

    CONTROL_NAME_CACHE["${control_arn}"]="${display_name}"
    echo "${display_name}"
}

# --- Markdown-Tabelle generieren ---------------------------------------------
generate_markdown() {
    log_info "Generiere Markdown-Datei: ${OUTPUT_FILE}"
    log_info "Löse OU-Pfade und Control-Namen auf (API-Calls laufen – bitte warten)..."

    local resolved=0

    {
        echo "# AWS Control Tower – Aktivierte Controls"
        echo ""
        echo "> Exportiert am: \`${TIMESTAMP}\`  "
        echo "> AWS Account: \`${ACCOUNT_ID}\`  "
        echo "> Region: \`${REGION}\`  "
        echo "> Gesamtanzahl aktivierter Controls: **${TOTAL_COUNT}**"
        echo ""
        echo "---"
        echo ""
        echo "| # | Control Name | OU-Pfad |"
        echo "|---|:-------------|:--------|"

        local INDEX=1
        for CONTROL_JSON in "${ALL_CONTROLS[@]}"; do
            local TARGET_ARN CONTROL_ARN OU_PATH CONTROL_NAME

            TARGET_ARN=$(echo "${CONTROL_JSON}" | jq -r '.targetIdentifier // .targetArn // "N/A"')
            CONTROL_ARN=$(echo "${CONTROL_JSON}" | jq -r '.controlIdentifier // .arn // "N/A"')

            # OU-Pfad auflösen
            if [[ "${TARGET_ARN}" == "N/A" ]]; then
                OU_PATH="N/A"
            else
                OU_PATH=$(get_ou_full_path "${TARGET_ARN}")
            fi

            # Lesbaren Control-Namen abrufen
            if [[ "${CONTROL_ARN}" == "N/A" ]]; then
                CONTROL_NAME="N/A"
            else
                CONTROL_NAME=$(get_control_display_name "${CONTROL_ARN}")
            fi

            printf "| %d | %s | %s |\n" \
                "${INDEX}" \
                "${CONTROL_NAME}" \
                "${OU_PATH}"

            INDEX=$((INDEX + 1))
            resolved=$((resolved + 1))

            # Fortschrittsanzeige im Terminal (alle 10 Controls)
            if (( resolved % 10 == 0 )); then
                log_info "  ${resolved}/${TOTAL_COUNT} Controls verarbeitet..." >&2
            fi
        done

        echo ""
        echo "---"
        echo ""
        echo "## Legende"
        echo ""
        echo "| Spalte | Beschreibung |"
        echo "|--------|:-------------|"
        echo "| **Control Name** | Lesbarer Anzeigename des Controls (via \`controltower:GetControl → displayName\`) |"
        echo "| **OU-Pfad** | Vollständiger Pfad der Organizational Unit, auf die das Control angewendet wird (z. B. \`Root / Security / Production\`) |"
        echo ""
        echo "*Generiert mit \`export_controltower_controls.sh\`*"

    } > "${OUTPUT_FILE}"

    log_ok "Markdown-Datei erfolgreich geschrieben: ${OUTPUT_FILE}"
}

# --- Zusammenfassung ---------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         Export erfolgreich abgeschlossen             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Ausgabedatei : ${CYAN}${OUTPUT_FILE}${NC}"
    echo -e "  Controls     : ${CYAN}${TOTAL_COUNT}${NC}"
    echo -e "  Account      : ${CYAN}${ACCOUNT_ID}${NC}"
    echo -e "  Region       : ${CYAN}${REGION}${NC}"
    echo -e "  Zeitstempel  : ${CYAN}${TIMESTAMP}${NC}"
    echo ""
    echo "  Tabellenvorschau:"
    echo ""
    grep -A 7 '| # |' "${OUTPUT_FILE}" | head -10 || true
    echo ""
    echo -e "  ${YELLOW}cat ${OUTPUT_FILE}${NC}"
    echo -e "  ${YELLOW}# CloudShell: Aktionen → Dateien herunterladen → ${OUTPUT_FILE}${NC}"
    echo ""
}

# --- Main --------------------------------------------------------------------
main() {
    echo ""
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN}  AWS Control Tower – Controls Export Script     ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo ""

    check_prerequisites
    fetch_enabled_controls
    generate_markdown
    print_summary
}

main "$@"
