# Export aws organization and control tower

## Prompt
Aufbauend auf dem vorherigen Script:

Ich würde gerne das Skript noch in so weit erweitern, dass es zusätzlich noch alle Compliance-Regelungen (sprich Controls) aus dem Control Tower auflistet, die den jeweiligen Accounts zugeordnet sind.
## Result
```bash
#!/bin/bash
# =============================================================================
# AWS Organization Account Export + Control Tower Controls
# Exportiert alle Account-Infos (inkl. Tags) und die zugeordneten
# Control Tower Controls je Account als zwei separate CSV-Dateien.
#
# Voraussetzungen:
#   - AWS CloudShell im Management Account ODER delegierter Admin
#   - IAM: organizations:List*, organizations:Describe*,
#          organizations:ListTagsForResource,
#          controltower:ListEnabledControls, controltower:GetControl
#   - jq (in CloudShell vorinstalliert)
# =============================================================================

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ACCOUNTS_CSV="aws_accounts_export_${TIMESTAMP}.csv"
CONTROLS_CSV="aws_controls_detail_${TIMESTAMP}.csv"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'

print_header() { echo -e "\n${CYAN}$1${NC}"; }
ok()           { echo -e "${GREEN}  ✔ $1${NC}"; }
warn()         { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()          { echo -e "${RED}  ✖ $1${NC}"; }

echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║  AWS Organization + Control Tower Export     ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# =============================================================================
# [1/7] Voraussetzungen prüfen
# =============================================================================
print_header "[1/7] Prüfe Voraussetzungen..."

if ! aws organizations describe-organization &>/dev/null; then
  err "Kein Zugriff auf AWS Organizations."
  echo "     Stelle sicher, dass du im Management Account angemeldet bist."
  exit 1
fi

ORG_ID=$(aws organizations describe-organization \
  --query 'Organization.Id' --output text)
MASTER_ACCOUNT=$(aws organizations describe-organization \
  --query 'Organization.MasterAccountId' --output text)
ROOT_ID=$(aws organizations list-roots \
  --query 'Roots[0].Id' --output text)

ok "Organisation:    ${ORG_ID}"
ok "Mgmt. Account:   ${MASTER_ACCOUNT}"
ok "Root ID:         ${ROOT_ID}"

# Control Tower Home Region ermitteln
CT_AVAILABLE=false
CT_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"

echo -e "\n  Suche Control Tower Home Region..."
for region in eu-central-1 us-east-1 us-west-2 eu-west-1 ap-southeast-1 ap-northeast-1; do
  LZ_COUNT=$(aws controltower list-landing-zones --region "$region" \
    --query 'length(landingZones)' --output text 2>/dev/null || echo "0")
  if [[ "$LZ_COUNT" -gt 0 ]]; then
    CT_AVAILABLE=true
    CT_REGION="$region"
    ok "Control Tower gefunden in Region: ${CT_REGION}"
    break
  fi
done

if [[ "$CT_AVAILABLE" == "false" ]]; then
  warn "Control Tower nicht gefunden. Controls werden nicht exportiert."
  warn "Accounts-Export wird trotzdem durchgeführt."
fi

# =============================================================================
# [2/7] Alle Accounts laden
# =============================================================================
print_header "[2/7] Lade alle Accounts..."

aws organizations list-accounts \
  --query 'Accounts[*]' \
  --output json > "$TEMP_DIR/accounts.json"

ACCOUNT_COUNT=$(jq length "$TEMP_DIR/accounts.json")
ok "${ACCOUNT_COUNT} Accounts gefunden."

# =============================================================================
# [3/7] Gesamte OU-Hierarchie cachen (BFS)
# =============================================================================
print_header "[3/7] Indexiere OU-Hierarchie..."

declare -A OU_NAME_CACHE    # ou_id  -> Name
declare -A OU_ARN_CACHE     # ou_id  -> ARN
declare -A OU_PARENT_CACHE  # ou_id  -> parent_id
declare -A OU_PATH_CACHE    # ou_id  -> Vollpfad (z.B. Root/Prod/Finance)

ROOT_ARN="arn:aws:organizations::${MASTER_ACCOUNT}:root/${ORG_ID}/${ROOT_ID}"
OU_NAME_CACHE["$ROOT_ID"]="Root"
OU_ARN_CACHE["$ROOT_ID"]="$ROOT_ARN"
OU_PARENT_CACHE["$ROOT_ID"]=""
OU_PATH_CACHE["$ROOT_ID"]="Root"

declare -a QUEUE=("$ROOT_ID")
declare -a ALL_OU_IDS=()

while [[ ${#QUEUE[@]} -gt 0 ]]; do
  current="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")
  ALL_OU_IDS+=("$current")

  child_ous=$(aws organizations list-organizational-units-for-parent \
    --parent-id "$current" \
    --query 'OrganizationalUnits[*]' \
    --output json 2>/dev/null || echo '[]')

  while IFS= read -r ou; do
    ou_id=$(echo "$ou"   | jq -r '.Id')
    ou_name=$(echo "$ou" | jq -r '.Name')
    ou_arn=$(echo "$ou"  | jq -r '.Arn')

    OU_NAME_CACHE["$ou_id"]="$ou_name"
    OU_ARN_CACHE["$ou_id"]="$ou_arn"
    OU_PARENT_CACHE["$ou_id"]="$current"
    OU_PATH_CACHE["$ou_id"]="${OU_PATH_CACHE[$current]}/${ou_name}"

    QUEUE+=("$ou_id")
  done < <(echo "$child_ous" | jq -c '.[]' 2>/dev/null || true)
done

ok "${#ALL_OU_IDS[@]} OUs indexiert (inkl. Root)."

# Hilfsfunktion: Gibt OU-ID-Kette (Root -> direkte Parent-OU) zurueck
get_account_ou_chain() {
  local account_id="$1"
  local current_id="$account_id"
  local -a chain=()

  while true; do
    local parent_json parent_id parent_type
    parent_json=$(aws organizations list-parents \
      --child-id "$current_id" \
      --query 'Parents[0]' \
      --output json 2>/dev/null || echo '{}')

    parent_id=$(echo "$parent_json"   | jq -r '.Id   // empty')
    parent_type=$(echo "$parent_json" | jq -r '.Type // empty')

    [[ -z "$parent_id" ]] && break
    chain=("$parent_id" "${chain[@]}")
    [[ "$parent_type" == "ROOT" ]] && break
    current_id="$parent_id"
  done

  echo "${chain[@]:-}"
}

# =============================================================================
# [4/7] Control Tower Controls pro OU cachen
# =============================================================================
print_header "[4/7] Lade Control Tower Controls je OU..."

declare -A OU_CONTROLS_CACHE      # ou_id -> JSON-Array der enabled controls
declare -A CONTROL_NAME_CACHE     # control_arn -> Anzeigename
declare -A CONTROL_BEHAVIOR_CACHE # control_arn -> PREVENTIVE / DETECTIVE / PROACTIVE
declare -A CONTROL_SEVERITY_CACHE # control_arn -> HIGH / MEDIUM / LOW etc.

if [[ "$CT_AVAILABLE" == "true" ]]; then
  TOTAL_OUS=${#ALL_OU_IDS[@]}
  OU_CTR=0

  for ou_id in "${ALL_OU_IDS[@]}"; do
    OU_CTR=$((OU_CTR + 1))
    ou_arn="${OU_ARN_CACHE[$ou_id]}"
    ou_display="${OU_PATH_CACHE[$ou_id]}"
    echo -ne "\r  OU ${OU_CTR}/${TOTAL_OUS}: ${ou_display}                    "

    # Paginierung fuer list-enabled-controls
    all_controls_json="[]"
    next_token=""
    while true; do
      if [[ -n "$next_token" ]]; then
        page=$(aws controltower list-enabled-controls \
          --target-identifier "$ou_arn" \
          --region "$CT_REGION" \
          --next-token "$next_token" \
          --output json 2>/dev/null || echo '{"enabledControls":[]}')
      else
        page=$(aws controltower list-enabled-controls \
          --target-identifier "$ou_arn" \
          --region "$CT_REGION" \
          --output json 2>/dev/null || echo '{"enabledControls":[]}')
      fi

      page_controls=$(echo "$page" | jq '.enabledControls // []')
      all_controls_json=$(echo "$all_controls_json $page_controls" | jq -s 'add')
      next_token=$(echo "$page" | jq -r '.nextToken // empty')
      [[ -z "$next_token" ]] && break
    done

    OU_CONTROLS_CACHE["$ou_id"]="$all_controls_json"

    # Metadaten fuer noch unbekannte Controls nachladen
    while IFS= read -r ctrl_arn; do
      [[ -z "$ctrl_arn" ]] && continue
      [[ -v CONTROL_NAME_CACHE["$ctrl_arn"] ]] && continue

      ctrl_detail=$(aws controltower get-control \
        --control-identifier "$ctrl_arn" \
        --region "$CT_REGION" \
        --output json 2>/dev/null || echo '{}')

      CONTROL_NAME_CACHE["$ctrl_arn"]=$(echo "$ctrl_detail" | \
        jq -r '.control.name // .control.title // "Unknown"')
      CONTROL_BEHAVIOR_CACHE["$ctrl_arn"]=$(echo "$ctrl_detail" | \
        jq -r '.control.behavior // "Unknown"')
      CONTROL_SEVERITY_CACHE["$ctrl_arn"]=$(echo "$ctrl_detail" | \
        jq -r '.control.severity // "Unknown"')

    done < <(echo "$all_controls_json" | \
      jq -r '.[].controlIdentifier // empty' 2>/dev/null)

  done

  TOTAL_CONTROLS=${#CONTROL_NAME_CACHE[@]}
  echo -e "\n"
  ok "Controls geladen: ${TOTAL_CONTROLS} eindeutige Controls ueber alle OUs."
else
  echo -e "  ${YELLOW}Uebersprungen.${NC}"
fi

# =============================================================================
# [5/7] Tag-Keys aller Accounts scannen
# =============================================================================
print_header "[5/7] Scanne Account-Tags..."

declare -A ALL_TAG_KEYS

while IFS= read -r account_id; do
  tags=$(aws organizations list-tags-for-resource \
    --resource-id "$account_id" \
    --query 'Tags[*]' \
    --output json 2>/dev/null || echo '[]')

  while IFS= read -r key; do
    [[ -n "$key" ]] && ALL_TAG_KEYS["$key"]=1
  done < <(echo "$tags" | jq -r '.[].Key')

done < <(jq -r '.[].Id' "$TEMP_DIR/accounts.json")

mapfile -t SORTED_TAG_KEYS < <(printf '%s\n' "${!ALL_TAG_KEYS[@]}" | sort)
ok "Gefundene Tag-Keys: ${SORTED_TAG_KEYS[*]:-keine}"

# =============================================================================
# Hilfsfunktion: CSV-Feldescaping (RFC 4180)
# =============================================================================
csv_escape() {
  local val="${1:-}"
  if [[ "$val" == *","* || "$val" == *'"'* || "$val" == *$'\n'* || "$val" == *";"* ]]; then
    val="${val//\"/\"\"}"
    echo "\"${val}\""
  else
    echo "$val"
  fi
}

# =============================================================================
# [6/7] accounts.csv generieren
# Spalten: Account-Stammdaten | OU-Pfad | Control-Zusammenfassung | Tags
# =============================================================================
print_header "[6/7] Generiere ${ACCOUNTS_CSV}..."

HEADER="AccountId,AccountName,Email,Status,JoinedMethod,JoinedTimestamp"
HEADER="${HEADER},OU_Path,IsMasterAccount"
HEADER="${HEADER},ControlCount,Controls_Summary"
for key in "${SORTED_TAG_KEYS[@]}"; do
  HEADER="${HEADER},Tag_${key//,/_}"
done
echo "$HEADER" > "$ACCOUNTS_CSV"

COUNTER=0
while IFS= read -r account; do
  COUNTER=$((COUNTER + 1))
  account_id=$(echo "$account"        | jq -r '.Id')
  account_name=$(echo "$account"      | jq -r '.Name')
  account_email=$(echo "$account"     | jq -r '.Email')
  account_status=$(echo "$account"    | jq -r '.Status')
  joined_method=$(echo "$account"     | jq -r '.JoinedMethod')
  joined_timestamp=$(echo "$account"  | jq -r '.JoinedTimestamp')
  is_master="false"
  [[ "$account_id" == "$MASTER_ACCOUNT" ]] && is_master="true"

  echo -ne "\r  [${COUNTER}/${ACCOUNT_COUNT}] ${account_name} (${account_id})           "

  # OU-Kette und Pfad
  read -ra ou_chain <<< "$(get_account_ou_chain "$account_id")"
  ou_path="Root"
  if [[ ${#ou_chain[@]} -gt 0 ]]; then
    direct_parent="${ou_chain[-1]}"
    ou_path="${OU_PATH_CACHE[$direct_parent]:-Root}"
  fi

  # Controls aus allen OUs der Kette aggregieren (dedupliziert, vererbt)
  declare -A seen_controls=()
  control_names_list=()

  for ou_id in "${ou_chain[@]}"; do
    ou_controls="${OU_CONTROLS_CACHE[$ou_id]:-[]}"
    while IFS= read -r ctrl_arn; do
      [[ -z "$ctrl_arn" || -v seen_controls["$ctrl_arn"] ]] && continue
      seen_controls["$ctrl_arn"]=1
      cname="${CONTROL_NAME_CACHE[$ctrl_arn]:-$(basename "$ctrl_arn")}"
      control_names_list+=("$cname")
    done < <(echo "$ou_controls" | jq -r '.[].controlIdentifier // empty' 2>/dev/null)
  done
  unset seen_controls

  control_count="${#control_names_list[@]}"
  controls_summary=""
  if [[ $control_count -gt 0 ]]; then
    controls_summary=$(IFS=';'; echo "${control_names_list[*]}")
  fi

  # Tags laden
  tags=$(aws organizations list-tags-for-resource \
    --resource-id "$account_id" \
    --query 'Tags[*]' \
    --output json 2>/dev/null || echo '[]')

  ROW=""
  ROW+="$(csv_escape "$account_id"),"
  ROW+="$(csv_escape "$account_name"),"
  ROW+="$(csv_escape "$account_email"),"
  ROW+="$(csv_escape "$account_status"),"
  ROW+="$(csv_escape "$joined_method"),"
  ROW+="$(csv_escape "$joined_timestamp"),"
  ROW+="$(csv_escape "$ou_path"),"
  ROW+="$(csv_escape "$is_master"),"
  ROW+="$(csv_escape "$control_count"),"
  ROW+="$(csv_escape "$controls_summary")"

  for key in "${SORTED_TAG_KEYS[@]}"; do
    tag_value=$(echo "$tags" | \
      jq -r --arg k "$key" '.[] | select(.Key == $k) | .Value // empty' \
      2>/dev/null || echo "")
    ROW+=",$(csv_escape "$tag_value")"
  done

  echo "$ROW" >> "$ACCOUNTS_CSV"

done < <(jq -c '.[]' "$TEMP_DIR/accounts.json")
echo -e "\n"

# =============================================================================
# [7/7] controls_detail.csv generieren
# Eine Zeile pro Account+Control (inkl. Vererbungsinfo)
# =============================================================================
print_header "[7/7] Generiere ${CONTROLS_CSV}..."

CTRL_HEADER="AccountId,AccountName,AccountOU_Path"
CTRL_HEADER+=",AppliedAt_OU_Name,AppliedAt_OU_Path"
CTRL_HEADER+=",ControlARN,ControlName,ControlBehavior,ControlSeverity"
echo "$CTRL_HEADER" > "$CONTROLS_CSV"

if [[ "$CT_AVAILABLE" == "true" ]]; then
  COUNTER=0
  while IFS= read -r account; do
    COUNTER=$((COUNTER + 1))
    account_id=$(echo "$account"   | jq -r '.Id')
    account_name=$(echo "$account" | jq -r '.Name')

    echo -ne "\r  [${COUNTER}/${ACCOUNT_COUNT}] ${account_name}           "

    read -ra ou_chain <<< "$(get_account_ou_chain "$account_id")"
    account_ou_path="Root"
    if [[ ${#ou_chain[@]} -gt 0 ]]; then
      account_ou_path="${OU_PATH_CACHE[${ou_chain[-1]}]:-Root}"
    fi

    declare -A seen_detail=()

    for ou_id in "${ou_chain[@]}"; do
      ou_controls="${OU_CONTROLS_CACHE[$ou_id]:-[]}"
      applied_ou_name="${OU_NAME_CACHE[$ou_id]:-$ou_id}"
      applied_ou_path="${OU_PATH_CACHE[$ou_id]:-$ou_id}"

      while IFS= read -r ctrl_arn; do
        [[ -z "$ctrl_arn" || -v seen_detail["$ctrl_arn"] ]] && continue
        seen_detail["$ctrl_arn"]=1

        cname="${CONTROL_NAME_CACHE[$ctrl_arn]:-$(basename "$ctrl_arn")}"
        cbehavior="${CONTROL_BEHAVIOR_CACHE[$ctrl_arn]:-Unknown}"
        cseverity="${CONTROL_SEVERITY_CACHE[$ctrl_arn]:-Unknown}"

        ROW=""
        ROW+="$(csv_escape "$account_id"),"
        ROW+="$(csv_escape "$account_name"),"
        ROW+="$(csv_escape "$account_ou_path"),"
        ROW+="$(csv_escape "$applied_ou_name"),"
        ROW+="$(csv_escape "$applied_ou_path"),"
        ROW+="$(csv_escape "$ctrl_arn"),"
        ROW+="$(csv_escape "$cname"),"
        ROW+="$(csv_escape "$cbehavior"),"
        ROW+="$(csv_escape "$cseverity")"

        echo "$ROW" >> "$CONTROLS_CSV"

      done < <(echo "$ou_controls" | jq -r '.[].controlIdentifier // empty' 2>/dev/null)
    done
    unset seen_detail

  done < <(jq -c '.[]' "$TEMP_DIR/accounts.json")
  echo -e "\n"
else
  warn "Control Tower nicht verfuegbar - ${CONTROLS_CSV} enthaelt nur den Header."
fi

# =============================================================================
# Abschluss-Zusammenfassung
# =============================================================================
ACCOUNT_LINES=$(( $(wc -l < "$ACCOUNTS_CSV") - 1 ))
CONTROL_LINES=$(( $(wc -l < "$CONTROLS_CSV") - 1 ))

echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║             Export abgeschlossen!            ║"
echo "  ╠══════════════════════════════════════════════╣"
printf  "  ║  %-44s║\n" ""
printf  "  ║  %-44s║\n" "Accounts CSV:  ${ACCOUNTS_CSV}"
printf  "  ║  %-44s║\n" "Controls CSV:  ${CONTROLS_CSV}"
printf  "  ║  %-44s║\n" ""
printf  "  ║  %-44s║\n" "  Accounts exportiert:  ${ACCOUNT_LINES}"
printf  "  ║  %-44s║\n" "  OUs indexiert:        ${#ALL_OU_IDS[@]}"
printf  "  ║  %-44s║\n" "  Tag-Spalten:          ${#SORTED_TAG_KEYS[@]}"
printf  "  ║  %-44s║\n" "  Control-Zeilen:       ${CONTROL_LINES}"
printf  "  ║  %-44s║\n" "  CT Region:            ${CT_REGION} (${CT_AVAILABLE})"
printf  "  ║  %-44s║\n" ""
echo "  ╠══════════════════════════════════════════════╣"
printf  "  ║  %-44s║\n" "Tipp: Actions > Download file"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"
```
