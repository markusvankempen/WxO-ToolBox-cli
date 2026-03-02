#!/bin/bash
#
# Create News Tool (NewsAPI.org) in TZ1 with connection, then export and replicate to TZ2.
# Reusable script for testing export/import of OpenAPI tools with connections.
#
# Usage:
#   ./create_and_replicate_news_tool.sh [OPTIONS]
#   ./create_and_replicate_news_tool.sh --source TZ1 --target TZ2
#
# Options:
#   --source <env>   Source env to create tool in (default: TZ1)
#   --target <env>   Target env to replicate to (default: TZ2)
#   --skip-create    Skip creation in source; only export+import (tool must exist)
#   -h, --help       Show help
#
# Prerequisites:
#   .env with WXO_API_KEY_<source>, WXO_API_KEY_<target>
#   WxO/Systems/<source>/Connections/.env_connection_<source> with CONN_NewsAPI_API_KEY=...
#
# Tool assets: WxO/Tools/News_Tool/ (skill_v2.json, connections/NewsAPI.yaml)
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
      echo "  Create News Tool in source env, export, replicate to target."
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

TOOL_SOURCE="$WXO_ROOT/Tools/News_Tool"
ENV_CONN_FILE="$WXO_ROOT/Systems/${SOURCE_ENV}/Connections/.env_connection_${SOURCE_ENV}"
EXPORT_SCRIPT="$SCRIPT_DIR/export_from_wxo.sh"
IMPORT_TOOL_SCRIPT="$SCRIPT_DIR/import_tool_with_connection.sh"

[[ ! -d "$TOOL_SOURCE" ]] || [[ ! -f "$TOOL_SOURCE/skill_v2.json" ]] && {
  echo "[ERROR] News Tool not found at $TOOL_SOURCE. Ensure WxO/Tools/News_Tool/ exists with skill_v2.json and connections/NewsAPI.yaml"
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
echo "  News Tool: Create in $SOURCE_ENV → Export → Replicate to $TARGET_ENV"
echo "  ═══════════════════════════════════════════════════════════"
echo ""

# Step 1: Create in source (unless skipped)
if ! $SKIP_CREATE; then
  echo "→ Step 1: Create News Tool in $SOURCE_ENV"
  _activate "$SOURCE_ENV" || exit 1
  bash "$IMPORT_TOOL_SCRIPT" -t "$TOOL_SOURCE" -e "$ENV_CONN_FILE" -n "$SOURCE_ENV" || {
    echo "[ERROR] Failed to create News Tool in $SOURCE_ENV"
    exit 1
  }
  echo ""
else
  echo "→ Step 1: Skip create (--skip-create)"
fi

# Step 2: Export from source (platform names it searchEverything from operationId)
echo "→ Step 2: Export News Tool from $SOURCE_ENV"
_activate "$SOURCE_ENV" || exit 1
bash "$EXPORT_SCRIPT" -o "$WXO_ROOT" --env-name "$SOURCE_ENV" --tools-only --tool "searchEverything" 2>/dev/null || {
  echo "[ERROR] Export failed. Is News_Tool present in $SOURCE_ENV?"
  exit 1
}
echo ""

# Resolve export dir (newest)
EXPORT_BASE="$WXO_ROOT/Exports/${SOURCE_ENV}"
[[ ! -d "$EXPORT_BASE" ]] && { echo "[ERROR] No export dir"; exit 1; }
EXPORT_DIR="$EXPORT_BASE/$(ls -1t "$EXPORT_BASE" 2>/dev/null | head -1)"
NEWS_TOOL_EXPORT="$EXPORT_DIR/tools/searchEverything"
[[ ! -d "$NEWS_TOOL_EXPORT" ]] && NEWS_TOOL_EXPORT="$EXPORT_DIR/tools/News_Tool"
[[ ! -d "$NEWS_TOOL_EXPORT" ]] && NEWS_TOOL_EXPORT=$(find "$EXPORT_DIR" -type d -name "News_Tool" -o -name "searchEverything" 2>/dev/null | head -1)
[[ ! -d "$NEWS_TOOL_EXPORT" ]] && { echo "[ERROR] News Tool not found in export $EXPORT_DIR"; exit 1; }

# Step 3: Import to target
echo "→ Step 3: Import News Tool to $TARGET_ENV"
bash "$IMPORT_TOOL_SCRIPT" -t "$NEWS_TOOL_EXPORT" -e "$ENV_CONN_FILE" -n "$TARGET_ENV" || {
  echo "[ERROR] Failed to import to $TARGET_ENV"
  exit 1
}
echo ""
echo "✓ Done. News Tool created in $SOURCE_ENV and replicated to $TARGET_ENV."
echo "  Export: $EXPORT_DIR"
echo ""
