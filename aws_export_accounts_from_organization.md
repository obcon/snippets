# Export accounts from aws organization

### CC-Prompt

Ich habe eine Organisation in AWS, die diverse Accounts in verschiedenen Organisational Units enthält. Bitte exportiere mir alle Account Informationen als Liste. Das heißt, ich möchte die Account ID, den Owner Kontaktdaten, Kostenstelle und so weiter. Diverse Informationen findest du in den Tags an den Accounts. Bitte erzeuge mir ein Skript auf Basis von AWS CLI die ich in einer Cloud Shell direkt in AWS laufen lassen kann

### Result
```bash
#!/bin/bash
# =============================================================================
# AWS Organization Account Export
# Exportiert alle Account-Informationen inkl. Tags als CSV
# Ausführen in AWS CloudShell mit Management Account oder delegiertem Admin
# =============================================================================

set -euo pipefail

OUTPUT_FILE="aws_accounts_export_$(date +%Y%m%d_%H%M%S).csv"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Farben für die Ausgabe
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  AWS Organization Account Export       ${NC}"
echo -e "${CYAN}========================================${NC}"

# --- Voraussetzungen prüfen ---
echo -e "\n${YELLOW}[1/5] Prüfe Voraussetzungen...${NC}"

if ! aws organizations describe-organization &>/dev/null; then
  echo -e "${RED}FEHLER: Kein Zugriff auf AWS Organizations.${NC}"
  echo "Stelle sicher, dass du im Management Account oder als delegierter Admin angemeldet bist."
  exit 1
fi

ORG_ID=$(aws organizations describe-organization --query 'Organization.Id' --output text)
MASTER_ACCOUNT=$(aws organizations describe-organization --query 'Organization.MasterAccountId' --output text)
echo -e "${GREEN}Organisation gefunden: ${ORG_ID} (Management Account: ${MASTER_ACCOUNT})${NC}"

# --- Alle Accounts laden ---
echo -e "\n${YELLOW}[2/5] Lade alle Accounts...${NC}"

aws organizations list-accounts \
  --query 'Accounts[*]' \
  --output json > "$TEMP_DIR/accounts.json"

ACCOUNT_COUNT=$(jq length "$TEMP_DIR/accounts.json")
echo -e "${GREEN}${ACCOUNT_COUNT} Accounts gefunden.${NC}"

# --- OU-Struktur aufbauen ---
echo -e "\n${YELLOW}[3/5] Lade Organizational Units Struktur...${NC}"

# Hilfsfunktion: OU-Pfad für einen Account ermitteln
get_ou_path() {
  local account_id="$1"
  local parents
  local path=""
  local current_id="$account_id"
  local current_type="ACCOUNT"

  while true; do
    parents=$(aws organizations list-parents \
      --child-id "$current_id" \
      --query 'Parents[0]' \
      --output json 2>/dev/null || echo '{}')

    local parent_id parent_type
    parent_id=$(echo "$parents" | jq -r '.Id // empty')
    parent_type=$(echo "$parents" | jq -r '.Type // empty')

    if [[ -z "$parent_id" ]]; then
      break
    fi

    if [[ "$parent_type" == "ROOT" ]]; then
      path="Root${path:+/}${path}"
      break
    fi

    local ou_name
    ou_name=$(aws organizations describe-organizational-unit \
      --organizational-unit-id "$parent_id" \
      --query 'OrganizationalUnit.Name' \
      --output text 2>/dev/null || echo "$parent_id")

    path="${ou_name}${path:+/}${path}"
    current_id="$parent_id"
    current_type="$parent_type"
  done

  echo "$path"
}

# --- Tags für alle Accounts laden ---
echo -e "\n${YELLOW}[4/5] Lade Tags und Kontaktdaten...${NC}"

# Alle einzigartigen Tag-Keys sammeln (für CSV-Header)
declare -A ALL_TAG_KEYS

echo -e "  Scanne Tag-Keys..."
while IFS= read -r account_id; do
  tags=$(aws organizations list-tags-for-resource \
    --resource-id "$account_id" \
    --query 'Tags[*]' \
    --output json 2>/dev/null || echo '[]')

  while IFS= read -r key; do
    ALL_TAG_KEYS["$key"]=1
  done < <(echo "$tags" | jq -r '.[].Key')

done < <(jq -r '.[].Id' "$TEMP_DIR/accounts.json")

# Tag-Keys sortiert als Array
mapfile -t SORTED_TAG_KEYS < <(printf '%s\n' "${!ALL_TAG_KEYS[@]}" | sort)
echo -e "${GREEN}  Gefundene Tag-Keys: ${SORTED_TAG_KEYS[*]:-keine}${NC}"

# --- CSV generieren ---
echo -e "\n${YELLOW}[5/5] Generiere CSV Export...${NC}"

# CSV-Header
HEADER="AccountId,AccountName,Email,Status,JoinedMethod,JoinedTimestamp,OU_Path,IsMasterAccount"
for key in "${SORTED_TAG_KEYS[@]}"; do
  # Sonderzeichen im Header escapen
  HEADER="${HEADER},Tag_${key//,/_}"
done

echo "$HEADER" > "$OUTPUT_FILE"

# Jeden Account verarbeiten
COUNTER=0
while IFS= read -r account; do
  COUNTER=$((COUNTER + 1))
  account_id=$(echo "$account" | jq -r '.Id')
  account_name=$(echo "$account" | jq -r '.Name')
  account_email=$(echo "$account" | jq -r '.Email')
  account_status=$(echo "$account" | jq -r '.Status')
  joined_method=$(echo "$account" | jq -r '.JoinedMethod')
  joined_timestamp=$(echo "$account" | jq -r '.JoinedTimestamp')
  is_master="false"
  [[ "$account_id" == "$MASTER_ACCOUNT" ]] && is_master="true"

  echo -ne "\r  Verarbeite Account ${COUNTER}/${ACCOUNT_COUNT}: ${account_name} (${account_id})   "

  # OU-Pfad ermitteln
  ou_path=$(get_ou_path "$account_id")

  # Tags laden
  tags=$(aws organizations list-tags-for-resource \
    --resource-id "$account_id" \
    --query 'Tags[*]' \
    --output json 2>/dev/null || echo '[]')

  # CSV-Zeile zusammenbauen (Felder mit Kommas in Anführungszeichen)
  csv_escape() {
    local val="$1"
    # Wenn Komma, Newline oder Anführungszeichen enthalten -> in "" einwickeln
    if [[ "$val" == *","* || "$val" == *'"'* || "$val" == *$'\n'* ]]; then
      val="${val//\"/\"\"}"
      val="\"${val}\""
    fi
    echo "$val"
  }

  ROW="$(csv_escape "$account_id"),$(csv_escape "$account_name"),$(csv_escape "$account_email"),$(csv_escape "$account_status"),$(csv_escape "$joined_method"),$(csv_escape "$joined_timestamp"),$(csv_escape "$ou_path"),$(csv_escape "$is_master")"

  # Tag-Werte in der richtigen Reihenfolge anhängen
  for key in "${SORTED_TAG_KEYS[@]}"; do
    tag_value=$(echo "$tags" | jq -r --arg k "$key" '.[] | select(.Key == $k) | .Value // empty' 2>/dev/null || echo "")
    ROW="${ROW},$(csv_escape "$tag_value")"
  done

  echo "$ROW" >> "$OUTPUT_FILE"

done < <(jq -c '.[]' "$TEMP_DIR/accounts.json")

echo -e "\n"

# --- Zusammenfassung ---
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}Export abgeschlossen!${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  Datei:        ${OUTPUT_FILE}"
echo -e "  Accounts:     ${COUNTER}"
echo -e "  Tag-Spalten:  ${#SORTED_TAG_KEYS[@]}"
echo -e "  Gesamt-Spalten: $(head -1 "$OUTPUT_FILE" | tr ',' '\n' | wc -l)"
echo ""
echo -e "${YELLOW}Tipp: In CloudShell kannst du die Datei über${NC}"
echo -e "${YELLOW}'Actions > Download file' herunterladen.${NC}"
echo -e "${CYAN}========================================${NC}"
```
