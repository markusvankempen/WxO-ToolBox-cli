#!/bin/bash
#
# Create FerryWeather tool in TZ1 with connection (basic auth), then export and replicate to TZ2.
#
# Usage:
#   ./create_and_replicate_ferry_weather_tool.sh [OPTIONS]
#   ./create_and_replicate_ferry_weather_tool.sh --source TZ1 --target TZ2
#
# Options:
#   --source <env>   Source env to create tool in (default: TZ1)
#   --target <env>   Target env to replicate to (default: TZ2)
#   --skip-create    Skip creation in source; only export+import (tool must exist)
#   -h, --help       Show help
#
# Prerequisites:
#   .env with WXO_API_KEY_<source>, WXO_API_KEY_<target>
#   .env_connection_<source> with CONN_FerryWeather_USERNAME and CONN_FerryWeather_PASSWORD
#
# Tool assets: WxO/Tools/FerryWeather/ (skill_v2.json, connections/FerryWeather.yaml)
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../../../.env}"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="$SCRIPT_DIR/../../.env"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="$SCRIPT_DIR/.env"
WXO_ROOT="${WXO_ROOT:-$SCRIPT_DIR/WxO}"

SOURCE_ENV="${SOURCE_ENV:-TZ1}"
TARGET_ENV="${TARGET_ENV:-TZ2}"
SKIP_CREATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)     SOURCE_ENV="${2:-TZ1}"; shift 2 ;;
    --target)     TARGET_ENV="${2:-TZ2}"; shift 2 ;;
    --skip-create) SKIP_CREATE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo "  Create FerryWeather tool in source env, export, replicate to target."
      echo ""
      echo "Options:"
      echo "  --source <env>   Source (default: TZ1)"
      echo "  --target <env>   Target (default: TZ2)"
      echo "  --skip-create    Skip create; only export+import"
      exit 0
      ;;
    *) echo "[WARN] Unknown: $1"; shift ;;
  esac
done

[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE" 2>/dev/null; set +a; }
command -v orchestrate >/dev/null 2>&1 || { echo "[ERROR] orchestrate CLI not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq not found"; exit 1; }

TOOL_SOURCE="$WXO_ROOT/Tools/FerryWeather"
ENV_CONN_FILE="$WXO_ROOT/Systems/${SOURCE_ENV}/Connections/.env_connection_${SOURCE_ENV}"
EXPORT_SCRIPT="$SCRIPT_DIR/export_from_wxo.sh"
IMPORT_TOOL_SCRIPT="$SCRIPT_DIR/import_tool_with_connection.sh"

[[ ! -d "$TOOL_SOURCE" ]] || [[ ! -f "$TOOL_SOURCE/skill_v2.json" ]] && {
  echo "[ERROR] FerryWeather tool not found at $TOOL_SOURCE. Ensure WxO/Tools/FerryWeather/ exists with skill_v2.json and connections/FerryWeather.yaml"
  exit 1
}

_activate() {
  local env="$1"
  local key_var="WXO_API_KEY_${env}"
  local key="${!key_var}"
  [[ -z "$key" ]] && { echo "[ERROR] No $key_var in .env"; return 1; }
  orchestrate env activate "$env" --api-key "$key" 2>/dev/null || return 1
  return 0
}

echo ""
echo "  ═══════════════════════════════════════════════════════════"
echo "  FerryWeather: Create in $SOURCE_ENV → Export → Replicate to $TARGET_ENV"
echo "  ═══════════════════════════════════════════════════════════"
echo ""

# Step 1: Create in source (unless skipped)
if ! $SKIP_CREATE; then
  echo "→ Step 1: Create FerryWeather tool in $SOURCE_ENV"
  _activate "$SOURCE_ENV" || exit 1
  bash "$IMPORT_TOOL_SCRIPT" -t "$TOOL_SOURCE" -e "$ENV_CONN_FILE" -n "$SOURCE_ENV" || {
    echo "[ERROR] Failed to create FerryWeather tool in $SOURCE_ENV"
    exit 1
  }
  echo ""
else
  echo "→ Step 1: Skip create (--skip-create)"
fi

# Step 2: Export from source (platform may name tool getFerryWeather from operationId, or FerryWeather)
echo "→ Step 2: Export FerryWeather from $SOURCE_ENV"
_activate "$SOURCE_ENV" || exit 1
bash "$EXPORT_SCRIPT" -o "$WXO_ROOT" --env-name "$SOURCE_ENV" --tools-only --tool "getFerryWeather" 2>/dev/null || \
bash "$EXPORT_SCRIPT" -o "$WXO_ROOT" --env-name "$SOURCE_ENV" --tools-only --tool "FerryWeather" 2>/dev/null || {
  echo "[ERROR] Export failed. Is FerryWeather present in $SOURCE_ENV?"
  exit 1
}
echo ""

# Resolve export dir (newest)
EXPORT_BASE="$WXO_ROOT/Exports/${SOURCE_ENV}"
[[ ! -d "$EXPORT_BASE" ]] && { echo "[ERROR] No export dir"; exit 1; }
EXPORT_DIR="$EXPORT_BASE/$(ls -1t "$EXPORT_BASE" 2>/dev/null | head -1)"
FERRY_EXPORT="$EXPORT_DIR/tools/FerryWeather"
[[ ! -d "$FERRY_EXPORT" ]] && FERRY_EXPORT="$EXPORT_DIR/tools/getFerryWeather"
[[ ! -d "$FERRY_EXPORT" ]] && FERRY_EXPORT=$(find "$EXPORT_DIR" -type d -name "FerryWeather" -o -name "getFerryWeather" 2>/dev/null | head -1)
[[ ! -d "$FERRY_EXPORT" ]] && { echo "[ERROR] FerryWeather not found in export $EXPORT_DIR"; exit 1; }

# Step 3: Import to target
echo "→ Step 3: Import FerryWeather to $TARGET_ENV"
bash "$IMPORT_TOOL_SCRIPT" -t "$FERRY_EXPORT" -e "$ENV_CONN_FILE" -n "$TARGET_ENV" || {
  echo "[ERROR] Failed to import to $TARGET_ENV"
  exit 1
}
echo ""
echo "✓ Done. FerryWeather created in $SOURCE_ENV and replicated to $TARGET_ENV."
echo "  Export: $EXPORT_DIR"
echo ""
