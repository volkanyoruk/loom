#!/bin/bash
# run_pipeline.sh — Tek komutla tam pipeline calistir
# Kullanim: ./run_pipeline.sh "Gorev aciklamasi" --project /path/to/project

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"

TASK="${1:?Kullanim: $0 \"Gorev aciklamasi\" [--project /path]}"
shift

PROJECT_ARGS=()
PROJECT_ROOT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --project) PROJECT_ROOT="$2"; PROJECT_ARGS=(--project "$2"); shift 2 ;;
        *) echo "Uyari: bilinmeyen parametre '$1'" >&2; shift ;;
    esac
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║    YOUDOWN BRAIN — Full Pipeline Runner      ║"
echo "╠══════════════════════════════════════════════╣"
echo "  Gorev : $TASK"
echo "  Proje : ${PROJECT_ROOT:-auto}"
echo "╚══════════════════════════════════════════════╝"
echo ""

# 1. Gorevi baslat
echo "━━━ ADIM 1: Gorev baslatiliyor ━━━"
bash "$AGENTS_DIR/start_task.sh" "$TASK" "${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"}"

# 2. Ece plan olustur
echo ""
echo "━━━ ADIM 2: Ece plan olusturuyor ━━━"
bash "$AGENTS_DIR/youdown-brain.sh" --role ece --mode pipeline "${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"}"

# 3. Ceylin dagit ve yonet
echo ""
echo "━━━ ADIM 3: Ceylin pipeline yonetiyor ━━━"
bash "$AGENTS_DIR/youdown-brain.sh" --role ceylin --mode pipeline "${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"}"

# 4. Final durum
echo ""
echo "━━━ PIPELINE TAMAMLANDI ━━━"
bash "$AGENTS_DIR/youdown-brain.sh" --status
