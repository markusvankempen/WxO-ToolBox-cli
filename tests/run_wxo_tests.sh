#!/bin/bash
#
# Script: run_wxo_tests.sh
# Description: Standalone test runner for WxO export/import permutations and related functions.
#   Runs export, import (various modes), validate, compare, and import_tool_with_connection.
#   Output goes to WxO/TestRun/<datetime>/ for inspection after code changes.
#
# Usage:
#   ./run_wxo_tests.sh [OPTIONS]
#   ./run_wxo_tests.sh --quick          # Subset for fast iteration
#   ./run_wxo_tests.sh --full           # All permutations (default)
#   ./run_wxo_tests.sh --list           # List test cases and exit
#
# Options:
#   --source <env>   Source environment (default: TZ1)
#   --target <env>   Target environment (default: TZ2)
#   --quick          Run quick subset (export tools+import tools+validate)
#   --full           Run all permutations (default)
#   --out-dir <dir>  Override output dir (default: WxO/TestRun/<datetime>)
#   --no-validate    Skip --validate after imports (faster)
#   --list           List test cases and exit
#
# Prerequisites: .env with WXO_API_KEY_<SOURCE>, WXO_API_KEY_<TARGET>
#   Optional: .env_connection_<SOURCE> for connection credentials when importing tools with conns
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../../../../.env}"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="$SCRIPT_DIR/../../../.env"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="$SCRIPT_DIR/../.env"

EXPORT_SCRIPT="$SCRIPT_DIR/../export_from_wxo.sh"
IMPORT_SCRIPT="$SCRIPT_DIR/../import_to_wxo.sh"
IMPORT_TOOL_SCRIPT="$SCRIPT_DIR/../import_tool_with_connection.sh"
NEWS_TOOL_SCRIPT="$SCRIPT_DIR/create_and_replicate_news_tool.sh"
FERRY_WEATHER_SCRIPT="$SCRIPT_DIR/create_and_replicate_ferry_weather_tool.sh"
COMPARE_SCRIPT="$SCRIPT_DIR/../compare_wxo_systems.sh"
WXO_ROOT="${WXO_ROOT:-$SCRIPT_DIR/../WxO}"

SOURCE_ENV="${SOURCE_ENV:-TZ1}"
TARGET_ENV="${TARGET_ENV:-TZ2}"
MODE="full"
SKIP_VALIDATE=false
OUT_DIR=""
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)    SOURCE_ENV="${2:-TZ1}"; shift 2 ;;
    --target)    TARGET_ENV="${2:-TZ2}"; shift 2 ;;
    --quick)     MODE="quick"; shift ;;
    --full)      MODE="full"; shift ;;
    --out-dir)   OUT_DIR="${2:-}"; shift 2 ;;
    --no-validate) SKIP_VALIDATE=true; shift ;;
    --list)      LIST_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo "  WxO test runner — export/import permutations, validate, compare"
      echo ""
      echo "Options:"
      echo "  --source <env>   Source env (default: TZ1)"
      echo "  --target <env>   Target env (default: TZ2)"
      echo "  --quick         Quick subset (tools export+import+validate)"
      echo "  --full          All permutations (default)"
      echo "  --out-dir <dir> Output dir (default: WxO/TestRun/<datetime>)"
      echo "  --no-validate   Skip agent validate after imports"
      echo "  --list          List test cases and exit"
      exit 0
      ;;
    *) echo "[WARN] Unknown: $1"; shift ;;
  esac
done

# --- Output directory ---
[[ -z "$OUT_DIR" ]] && OUT_DIR="$WXO_ROOT/TestRun/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"
REPORT_FILE="$OUT_DIR/test_report.txt"
LOG_DIR="$OUT_DIR/logs"
mkdir -p "$LOG_DIR"

# --- Helpers ---
_log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$REPORT_FILE" 2>/dev/null || echo "[$(date +%H:%M:%S)] $*"; }
_run() {
  local name="$1" cmd="$2" logfile="$LOG_DIR/${name//[^a-zA-Z0-9_-]/_}.log"
  _log "RUN: $name"
  set +e
  eval "$cmd" >"$logfile" 2>&1
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    _log "OK:  $name"
    return 0
  else
    _log "FAIL: $name (see $logfile)"
    return 1
  fi
}
_activate() {
  local env="$1"
  local key_var="WXO_API_KEY_${env}"
  local key="${!key_var}"
  [[ -z "$key" ]] && { _log "ERROR: No $key_var"; return 1; }
  orchestrate env activate "$env" --api-key "$key" 2>/dev/null || return 1
  return 0
}

# --- Load .env ---
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE" 2>/dev/null || true; set +a; }
# Fallback: try vscode-extension .env (uses SYNC_TZ1_API_KEY, WO_API_KEY)
if [[ -f "$SCRIPT_DIR/../../vscode-extension/.env" ]] && { [[ -z "${WXO_API_KEY_TZ1:-}" ]] || [[ -z "${WXO_API_KEY_TZ2:-}" ]]; }; then
  set -a; source "$SCRIPT_DIR/../../vscode-extension/.env" 2>/dev/null || true; set +a
fi
# Map common var names to WXO_* for compatibility
[[ -z "${WXO_API_KEY_TZ1:-}" ]] && [[ -n "${SYNC_TZ1_API_KEY:-}" ]] && WXO_API_KEY_TZ1="$SYNC_TZ1_API_KEY"
[[ -z "${WXO_API_KEY_TZ2:-}" ]] && [[ -n "${SYNC_TZ2_API_KEY:-}" ]] && WXO_API_KEY_TZ2="$SYNC_TZ2_API_KEY"
[[ -z "${WXO_API_KEY_TZ1:-}" ]] && [[ -n "${WO_API_KEY:-}" ]] && WXO_API_KEY_TZ1="$WO_API_KEY"
[[ -z "${WXO_API_KEY_TZ2:-}" ]] && [[ -n "${WO_API_KEY:-}" ]] && WXO_API_KEY_TZ2="$WO_API_KEY"

# --- List test cases ---
if $LIST_ONLY; then
  echo "Test cases (--full):"
  echo "  1. export_tools_only       Export tools from source"
  echo "  2. export_connections      Export connections from source"
  echo "  3. export_agents_only      Export agents (YAML) from source"
  echo "  4. export_flows_only       Export flows from source"
  echo "  5. export_plugins_only     Export plugins from source"
  echo "  6. import_tools_only       Import tools to target (no deps)"
  echo "  7. import_tools_with_conns Import tools with bundled connections"
  echo "  8. import_connections      Import connections only"
  echo "  9. import_agents_only      Import agents only"
  echo " 10. import_if_exists_skip   Import with --if-exists skip"
  echo " 11. import_validate         Import + --validate"
  echo " 12. import_plugins_only     Import plugins only (from plugins/)"
  echo " 13. import_tool_standalone  import_tool_with_connection.sh (Weather_Tool)"
  echo " 14. news_tool_replicate    Create News Tool in TZ1, export, replicate to TZ2"
  echo " 15. ferry_weather_replicate Create FerryWeather in TZ1, export, replicate to TZ2"
  echo " 16. compare_systems        Compare source vs target"
  echo ""
  echo "Quick mode: 1, 5, 10 (tools export, import, validate)"
  exit 0
fi

# --- Prereqs ---
command -v orchestrate >/dev/null 2>&1 || { _log "ERROR: orchestrate CLI not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { _log "ERROR: jq not found"; exit 1; }

echo ""
echo "  ═══════════════════════════════════════════════════════════"
echo "  WxO Test Runner — $MODE mode"
echo "  Output: $OUT_DIR"
echo "  Source: $SOURCE_ENV  →  Target: $TARGET_ENV"
echo "  ═══════════════════════════════════════════════════════════"
echo ""
{
  echo "WxO Test Run — $(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "Source: $SOURCE_ENV  Target: $TARGET_ENV  Mode: $MODE"
  echo "────────────────────────────────────────────────────────────"
} >"$REPORT_FILE"

FAIL_COUNT=0

# --- Resolve latest export dir (created by export steps) ---
_get_export_dir() {
  local sub="$1"  # e.g. "" or "TZ1"
  [[ -z "$sub" ]] && sub="$SOURCE_ENV"
  local base="$WXO_ROOT/Exports/${sub}"
  [[ ! -d "$base" ]] && echo "" && return
  ls -1t "$base" 2>/dev/null | head -1 | sed "s|^|$base/|"
}

# ═══════════════════════════════════════════════════════════════
# EXPORT TESTS
# ═══════════════════════════════════════════════════════════════
_log "--- EXPORT ---"
_activate "$SOURCE_ENV" || { _log "ERROR: Cannot activate $SOURCE_ENV"; exit 1; }

if [[ "$MODE" == "full" ]] || [[ "$MODE" == "quick" ]]; then
  _run "export_tools_only" \
    "bash \"$EXPORT_SCRIPT\" -o \"$WXO_ROOT\" --env-name \"$SOURCE_ENV\" --tools-only" || FAIL_COUNT=$((FAIL_COUNT+1))
  EXPORT_DIR=$(_get_export_dir)  # capture tools export for import tests (before other exports create newer dirs)
fi

if [[ "$MODE" == "full" ]]; then
  _run "export_connections" \
    "bash \"$EXPORT_SCRIPT\" -o \"$WXO_ROOT\" --env-name \"$SOURCE_ENV\" --connections-only" || FAIL_COUNT=$((FAIL_COUNT+1))
  _run "export_agents_only" \
    "bash \"$EXPORT_SCRIPT\" -o \"$WXO_ROOT\" --env-name \"$SOURCE_ENV\" --agents-only --agent-only" || FAIL_COUNT=$((FAIL_COUNT+1))
  _run "export_flows_only" \
    "bash \"$EXPORT_SCRIPT\" -o \"$WXO_ROOT\" --env-name \"$SOURCE_ENV\" --flows-only" || true  # may have no flows
  _run "export_plugins_only" \
    "bash \"$EXPORT_SCRIPT\" -o \"$WXO_ROOT\" --env-name \"$SOURCE_ENV\" --plugins-only" || true  # may have no plugins
fi

# ═══════════════════════════════════════════════════════════════
# IMPORT TESTS
# ═══════════════════════════════════════════════════════════════
_log "--- IMPORT ---"
_activate "$TARGET_ENV" || { _log "ERROR: Cannot activate $TARGET_ENV"; exit 1; }

[[ -z "${EXPORT_DIR:-}" ]] && EXPORT_DIR=$(_get_export_dir)
[[ -z "$EXPORT_DIR" ]] && { _log "WARN: No export dir; import tests may fail"; }

if [[ -n "$EXPORT_DIR" ]]; then
  VALIDATE_ARG=""
  $SKIP_VALIDATE || VALIDATE_ARG="--validate"

  if [[ "$MODE" == "full" ]] || [[ "$MODE" == "quick" ]]; then
    _run "import_tools_only" \
      "bash \"$IMPORT_SCRIPT\" --base-dir \"$EXPORT_DIR\" --env \"$TARGET_ENV\" --tools-only --no-credential-prompt --if-exists override --report-dir \"$OUT_DIR/import_tools\" 2>/dev/null" || FAIL_COUNT=$((FAIL_COUNT+1))
  fi

  if [[ "$MODE" == "full" ]]; then
    _run "import_tools_with_conns" \
      "bash \"$IMPORT_SCRIPT\" --base-dir \"$EXPORT_DIR\" --env \"$TARGET_ENV\" --all --no-credential-prompt --if-exists override --report-dir \"$OUT_DIR/import_all\" 2>/dev/null" || FAIL_COUNT=$((FAIL_COUNT+1))
    _run "import_connections" \
      "bash \"$IMPORT_SCRIPT\" --base-dir \"$EXPORT_DIR\" --env \"$TARGET_ENV\" --connections-only --no-credential-prompt --if-exists override 2>/dev/null" || true
    _run "import_agents_only" \
      "bash \"$IMPORT_SCRIPT\" --base-dir \"$EXPORT_DIR\" --env \"$TARGET_ENV\" --agents-only --agent-only --no-credential-prompt --if-exists skip --report-dir \"$OUT_DIR/import_agents\" 2>/dev/null" || true
    _run "import_if_exists_skip" \
      "bash \"$IMPORT_SCRIPT\" --base-dir \"$EXPORT_DIR\" --env \"$TARGET_ENV\" --tools-only --no-credential-prompt --if-exists skip 2>/dev/null" || true
    _run "import_plugins_only" \
      "bash \"$IMPORT_SCRIPT\" --base-dir \"$EXPORT_DIR\" --env \"$TARGET_ENV\" --plugins-only --no-credential-prompt --if-exists override 2>/dev/null" || true  # may have no plugins/
    if [[ -n "$VALIDATE_ARG" ]]; then
      _run "import_validate" \
        "bash \"$IMPORT_SCRIPT\" --base-dir \"$EXPORT_DIR\" --env \"$TARGET_ENV\" --agents-only --no-credential-prompt --if-exists skip $VALIDATE_ARG 2>/dev/null" || true
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════
# STANDALONE import_tool_with_connection
# ═══════════════════════════════════════════════════════════════
TOOL_EXPORT_DIR=$(_get_export_dir)
WEATHER_TOOL_DIR=""
if [[ -n "$TOOL_EXPORT_DIR" ]]; then
  WEATHER_TOOL_DIR="$TOOL_EXPORT_DIR/tools/Weather_Tool"
  [[ ! -d "$WEATHER_TOOL_DIR" ]] && WEATHER_TOOL_DIR=$(find "$TOOL_EXPORT_DIR" -type d -name "Weather_Tool" 2>/dev/null | head -1)
fi
ENV_CONN_FILE="$WXO_ROOT/Systems/${SOURCE_ENV}/Connections/.env_connection_${SOURCE_ENV}"

if [[ -n "$WEATHER_TOOL_DIR" ]] && [[ -f "$WEATHER_TOOL_DIR/skill_v2.json" ]] && [[ "$MODE" == "full" ]]; then
  _run "import_tool_standalone" \
    "bash \"$IMPORT_TOOL_SCRIPT\" -t \"$WEATHER_TOOL_DIR\" -e \"$ENV_CONN_FILE\" -n \"$TARGET_ENV\" 2>/dev/null" || true
else
  _log "SKIP: import_tool_standalone (no Weather_Tool or quick mode)"
fi

# ═══════════════════════════════════════════════════════════════
# NEWS TOOL REPLICATE (create in source, export, import to target)
# ═══════════════════════════════════════════════════════════════
if [[ "$MODE" == "full" ]] && [[ -f "$NEWS_TOOL_SCRIPT" ]] && [[ -d "$WXO_ROOT/Tools/News_Tool" ]]; then
  _run "news_tool_replicate" \
    "bash \"$NEWS_TOOL_SCRIPT\" --source \"$SOURCE_ENV\" --target \"$TARGET_ENV\" 2>/dev/null" || true
else
  _log "SKIP: news_tool_replicate (quick mode or News Tool assets missing)"
fi

# ═══════════════════════════════════════════════════════════════
# FERRY WEATHER REPLICATE (create in source, export, import to target)
# ═══════════════════════════════════════════════════════════════
if [[ "$MODE" == "full" ]] && [[ -f "$FERRY_WEATHER_SCRIPT" ]] && [[ -d "$WXO_ROOT/Tools/FerryWeather" ]]; then
  _run "ferry_weather_replicate" \
    "bash \"$FERRY_WEATHER_SCRIPT\" --source \"$SOURCE_ENV\" --target \"$TARGET_ENV\" 2>/dev/null" || true
else
  _log "SKIP: ferry_weather_replicate (quick mode or FerryWeather assets missing)"
fi

# ═══════════════════════════════════════════════════════════════
# COMPARE
# ═══════════════════════════════════════════════════════════════
if [[ "$MODE" == "full" ]]; then
  _run "compare_systems" \
    "bash \"$COMPARE_SCRIPT\" \"$SOURCE_ENV\" \"$TARGET_ENV\" -o \"$OUT_DIR/compare_report.txt\" 2>/dev/null" || true
fi

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════
{
  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo "Summary: $FAIL_COUNT failure(s)"
  echo "Logs:    $LOG_DIR"
  echo "Export:  $WXO_ROOT/Exports/$SOURCE_ENV/"
  echo ""
} | tee -a "$REPORT_FILE"

_log "Done. Report: $REPORT_FILE"
exit $FAIL_COUNT
