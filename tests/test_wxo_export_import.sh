#!/bin/bash
#
# Script: test_wxo_export_import.sh
# Author: Markus van Kempen <mvankempen@ca.ibm.com>, <markus.van.kempen@gmail.com>
# Date: Feb 25, 2026
#
# Description:
#   Test export/import flow (agents, tools, flows) between TZ1 and TZ2:
#   (1) Export MarkusMultiToolsAgent (with deps) from TZ1, import into TZ2
#   (2) Export name_address_agent (with Flow tool) from TZ1, import into TZ2 — validates flow export/import
#   Uses .env for API keys. Produces import report.
#
# Usage: ./test_wxo_export_import.sh
#
# Environment variables (optional, for non-interactive/CI):
#   WXO_API_KEY_TZ1   API key for TZ1 (otherwise prompted or loaded from .env)
#   WXO_API_KEY_TZ2   API key for TZ2 (otherwise prompted or loaded from .env)
#   WXO_TEST_DEBUG    Set to 1 for verbose progress messages

set -e
_debug() { [[ "${WXO_TEST_DEBUG:-0}" == "1" ]] && echo "[DEBUG] $*" || true; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# Look for .env in project root (../.. from internal/watsonXOrchetrate_auto_deploy-main)
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../../../../.env}"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="$SCRIPT_DIR/../../../.env"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="$SCRIPT_DIR/../.env"

EXPORT_SCRIPT="$SCRIPT_DIR/../export_from_wxo.sh"
DEPLOY_SCRIPT="$SCRIPT_DIR/../import_to_wxo.sh"
# Structure: WxO/Exports/TZ1/<DateTime>/agents|tools, WxO/Imports/TZ2/<DateTime>/Report/
WXO_ROOT="${WXO_ROOT:-$SCRIPT_DIR/../WxO}"

echo ""
echo "  ═══════════════════════════════════════════════════════════"
echo "  WXO Export/Import Test (Agents, Tools, Flows)"
echo "  ═══════════════════════════════════════════════════════════"
echo "  1. MarkusMultiToolsAgent: TZ1 → export → import → TZ2"
echo "  2. name_address_agent (Flow): TZ1 → export → import → TZ2"
echo ""

# --- API keys: from env, .env, or prompt ---
_debug "Checking API keys..."
# Fallback: try vscode-extension .env (SYNC_TZ1_API_KEY, WO_API_KEY)
if [[ -f "$SCRIPT_DIR/../../vscode-extension/.env" ]]; then
  set -a; source "$SCRIPT_DIR/../../vscode-extension/.env" 2>/dev/null || true; set +a
  [[ -z "${WXO_API_KEY_TZ1:-}" ]] && [[ -n "${SYNC_TZ1_API_KEY:-}" ]] && WXO_API_KEY_TZ1="$SYNC_TZ1_API_KEY"
  [[ -z "${WXO_API_KEY_TZ2:-}" ]] && [[ -n "${SYNC_TZ2_API_KEY:-}" ]] && WXO_API_KEY_TZ2="$SYNC_TZ2_API_KEY"
  [[ -z "${WXO_API_KEY_TZ1:-}" ]] && [[ -n "${WO_API_KEY:-}" ]] && WXO_API_KEY_TZ1="$WO_API_KEY"
  [[ -z "${WXO_API_KEY_TZ2:-}" ]] && [[ -n "${WO_API_KEY:-}" ]] && WXO_API_KEY_TZ2="$WO_API_KEY"
fi
need_keys=false
[[ -z "${WXO_API_KEY_TZ1:-}" ]] || [[ -z "${WXO_API_KEY_TZ2:-}" ]] && need_keys=true

if "$need_keys" && [[ -f "$ENV_FILE" ]]; then
  if [[ -t 0 ]]; then
    echo "Found .env at: $ENV_FILE"
    read -p "Use API keys from .env? (Y/n): " use_env
    use_env="${use_env:-Y}"
    use_env=$(printf '%s' "$use_env" | tr '[:upper:]' '[:lower:]')
    if [[ "$use_env" == "y" || "$use_env" == "yes" ]]; then
      _debug "Loading .env..."
      set -a
      # shellcheck source=/dev/null
      source "$ENV_FILE" 2>/dev/null || true
      set +a
      need_keys=false
      [[ -n "${WXO_API_KEY_TZ1:-}" ]] && [[ -n "${WXO_API_KEY_TZ2:-}" ]] && need_keys=false
      [[ -z "${WXO_API_KEY_TZ1:-}" ]] || [[ -z "${WXO_API_KEY_TZ2:-}" ]] && need_keys=true
      if ! "$need_keys"; then
        echo "[Step] Loaded keys from .env"
      else
        echo "[WARN] .env missing WXO_API_KEY_TZ1 or WXO_API_KEY_TZ2. Will prompt."
      fi
    fi
  else
    _debug "No TTY; trying to load .env..."
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE" 2>/dev/null || true
    set +a
    [[ -n "${WXO_API_KEY_TZ1:-}" ]] && [[ -n "${WXO_API_KEY_TZ2:-}" ]] && need_keys=false
  fi
fi

if "$need_keys"; then
  if [[ -z "${WXO_API_KEY_TZ1:-}" ]]; then
    if [[ ! -t 0 ]]; then
      echo "[ERROR] WXO_API_KEY_TZ1 not set and no TTY for prompt."
      echo "  Set it: export WXO_API_KEY_TZ1=your-tz1-api-key"
      echo "  Or add to .env: WXO_API_KEY_TZ1=..."
      echo "  Or run interactively to enter keys."
      exit 1
    fi
    echo "[Step] Prompting for TZ1 API key..."
    read -p "Enter API key for TZ1: " WXO_API_KEY_TZ1
    [[ -z "$WXO_API_KEY_TZ1" ]] && { echo "API key required."; exit 1; }
  fi
  if [[ -z "${WXO_API_KEY_TZ2:-}" ]]; then
    if [[ ! -t 0 ]]; then
      echo "[ERROR] WXO_API_KEY_TZ2 not set and no TTY for prompt."
      echo "  Set it: export WXO_API_KEY_TZ2=your-tz2-api-key"
      echo "  Or add to .env: WXO_API_KEY_TZ2=..."
      exit 1
    fi
    echo "[Step] Prompting for TZ2 API key..."
    read -p "Enter API key for TZ2: " WXO_API_KEY_TZ2
    [[ -z "$WXO_API_KEY_TZ2" ]] && { echo "API key required."; exit 1; }
  fi
fi
echo "[Step] API keys OK."

echo ""
echo "--- Step 1: Activate TZ1 and Export agents (with deps) ---"
echo ""
echo "[Step] Activating TZ1..."
orchestrate env activate TZ1 --api-key "$WXO_API_KEY_TZ1" || {
  echo "[ERROR] Failed to activate TZ1. Check env exists: orchestrate env list"
  exit 1
}
echo "[Step] TZ1 activated."
echo "[Step] Running export (MarkusMultiToolsAgent with deps from TZ1)..."
bash "$EXPORT_SCRIPT" -o "$WXO_ROOT" --env-name TZ1 --agents-only --agent MarkusMultiToolsAgent || {
  echo "[ERROR] Export failed."
  exit 1
}
# Resolve actual export dir (export creates WxO/Exports/TZ1/<datetime>)
EXPORT_DIR="$WXO_ROOT/Exports/TZ1/$(ls -1t "$WXO_ROOT/Exports/TZ1/" 2>/dev/null | head -1)"
# Agent folder in export uses id suffix (e.g. MarkusMultiToolsAgent_89536y)
AGENT_FOLDER=$(ls -1 "$EXPORT_DIR/agents/" 2>/dev/null | grep -i markusmultitoolsagent | head -1)
[[ -z "$AGENT_FOLDER" ]] && AGENT_FOLDER="MarkusMultiToolsAgent_89536y"  # fallback

# Patch Free_Weather_API skill_v2.json: add description for GET /v1/current.json (WXO requirement)
for spec in "$EXPORT_DIR"/agents/*/tools/*/skill_v2.json; do
  if [[ -f "$spec" ]] && jq -e '.paths["/v1/current.json"].get | select(.description == null or .description == "")' "$spec" >/dev/null 2>&1; then
    echo "[Step] Patching OpenAPI spec (add GET description): $(basename "$(dirname "$spec")")"
    jq '.paths["/v1/current.json"].get.description = "Get current weather data for a location (city name, zip, or lat/lon). Returns temperature, conditions, humidity, wind, and more."' "$spec" > "${spec}.tmp" && mv "${spec}.tmp" "$spec"
  fi
done

echo "[Step] Export complete."
echo ""
echo "--- Step 2: Activate TZ2 and Import $AGENT_FOLDER ---"
echo ""
_debug "Activating TZ2..."
orchestrate env activate TZ2 --api-key "$WXO_API_KEY_TZ2" || {
  echo "[ERROR] Failed to activate TZ2."
  exit 1
}
echo "[Step] TZ2 activated."
# Report in structured path: WxO/Imports/TZ2/<DateTime>/Report/import_report.txt
IMPORT_DATETIME=$(date +%Y%m%d_%H%M%S)
REPORT_DIR="$WXO_ROOT/Imports/TZ2/$IMPORT_DATETIME"
REPORT_PATH="$REPORT_DIR/Report/import_report.txt"
# Re-activate to ensure fresh token right before deploy (avoids expiry during long import)
orchestrate env activate TZ2 --api-key "$WXO_API_KEY_TZ2" 2>/dev/null || true
echo "[Step] Running import ($AGENT_FOLDER)..."
bash "$DEPLOY_SCRIPT" \
  --base-dir "$EXPORT_DIR" \
  --agent "$AGENT_FOLDER" \
  --no-credential-prompt \
  --report-dir "$REPORT_DIR" || true  # Don't exit yet - show report first

echo ""
if [[ -f "$REPORT_PATH" ]]; then
  cat "$REPORT_PATH"
else
  echo "(No report file generated)"
fi
# --- Step 3: Validate Flow export/import (name_address_agent with Flow tool) ---
echo ""
echo "--- Step 3: Validate Flow export/import (name_address_agent) ---"
echo ""
if orchestrate env activate TZ1 --api-key "$WXO_API_KEY_TZ1" 2>/dev/null; then
  if bash "$EXPORT_SCRIPT" -o "$WXO_ROOT" --env-name TZ1 --agents-only --agent name_address_agent 2>/dev/null; then
    EXPORT_DIR_FLOW="$WXO_ROOT/Exports/TZ1/$(ls -1t "$WXO_ROOT/Exports/TZ1/" 2>/dev/null | head -1)"
    AGENT_FLOW=$(ls -1 "$EXPORT_DIR_FLOW/agents/" 2>/dev/null | grep -i name_address_agent | head -1)
    [[ -z "$AGENT_FLOW" ]] && AGENT_FLOW="name_address_agent"
    echo "[Step] Importing $AGENT_FLOW (includes Flow tool) into TZ2..."
    orchestrate env activate TZ2 --api-key "$WXO_API_KEY_TZ2" 2>/dev/null || true
    IMPORT_DT2=$(date +%Y%m%d_%H%M%S)
    REPORT_DIR2="$WXO_ROOT/Imports/TZ2/$IMPORT_DT2"
    bash "$DEPLOY_SCRIPT" --base-dir "$EXPORT_DIR_FLOW" --agent "$AGENT_FLOW" --no-credential-prompt --report-dir "$REPORT_DIR2" 2>/dev/null || true
    REPORT_PATH2="$REPORT_DIR2/Report/import_report.txt"
    if [[ -f "$REPORT_PATH2" ]]; then
      echo ""
      cat "$REPORT_PATH2"
      grep -q "FAILED" "$REPORT_PATH2" && echo "[WARN] Some flow imports failed." || echo "[OK] Flow export/import validated: TZ1 -> TZ2."
    fi
  else
    echo "[INFO] name_address_agent not in TZ1 — skipping flow validation."
  fi
fi

echo ""
echo "  Test complete. Export: $EXPORT_DIR"
echo ""
if [[ -f "$REPORT_PATH" ]] && grep -q "FAILED" "$REPORT_PATH"; then exit 1; fi
