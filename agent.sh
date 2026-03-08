#!/bin/bash
# agents/agent.sh — Autonomous C+ Protocol Agent v2
# Opus 4.6 | Dosya okuma/yazma | Build dongusu | Tam otonom

set -euo pipefail

source "$(dirname "$0")/lib/protocol.sh"

MY_ROLE=""
POLL_INTERVAL=3
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --role) MY_ROLE="$2"; shift 2 ;;
        --poll) POLL_INTERVAL="$2"; shift 2 ;;
        *) echo "Usage: $0 --role main|mini"; exit 1 ;;
    esac
done

[ -z "$MY_ROLE" ] && echo "Error: --role required" && exit 1
[[ "$MY_ROLE" != "main" && "$MY_ROLE" != "mini" ]] && echo "Error: role must be main or mini" && exit 1

PEER_ROLE=$([[ "$MY_ROLE" == "main" ]] && echo "mini" || echo "main")

read_project_files() {
    local key_files=(
        "Sources/YouTubeDownloader/Services/DownloadManager.swift"
        "Sources/YouTubeDownloader/Services/ProcessRunner.swift"
        "Sources/YouTubeDownloader/Services/VideoInfoService.swift"
        "Sources/YouTubeDownloader/Services/ProgressParser.swift"
        "Sources/YouTubeDownloader/Views/ContentView.swift"
        "Sources/YouTubeDownloader/Views/URLInputView.swift"
        "Sources/YouTubeDownloader/Views/DownloadRowView.swift"
        "Sources/YouTubeDownloader/Views/DownloadQueueView.swift"
        "Sources/YouTubeDownloader/ViewModels/DownloadQueueViewModel.swift"
        "Sources/YouTubeDownloader/YouTubeDownloaderApp.swift"
        "Sources/YouTubeDownloader/Utilities/UserDefaultsManager.swift"
        "Package.swift"
    )
    for f in "${key_files[@]}"; do
        local full="$PROJECT_ROOT/$f"
        [ -f "$full" ] && printf '### %s\n```swift\n%s\n```\n\n' "$f" "$(cat "$full")"
    done
}

run_build() {
    log "$MY_ROLE" "swift build baslatiliyor..."
    local output exit_code=0
    output=$(cd "$PROJECT_ROOT" && swift build -c release 2>&1) || exit_code=$?
    if [ $exit_code -eq 0 ]; then
        log "$MY_ROLE" "BUILD BASARILI"
        printf 'BUILD_SUCCESS\n%s' "$output"
    else
        log "$MY_ROLE" "BUILD HATALI"
        printf 'BUILD_FAILED\n%s' "$output"
    fi
}

apply_code_changes() {
    local reply="$1"
    printf '%s' "$reply" | PROJECT_ROOT="$PROJECT_ROOT" python3 - << 'PYEOF'
import sys, re, os
content = sys.stdin.read()
project_root = os.environ.get('PROJECT_ROOT', '')
pattern = r'###\s+(Sources/[^\n]+\.swift)\n```swift\n(.*?)```'
for filepath, code in re.findall(pattern, content, re.DOTALL):
    filepath = filepath.strip()
    full = os.path.join(project_root, filepath)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'w').write(code)
    print(f"WROTE: {filepath}")
PYEOF
}

if [ "$MY_ROLE" = "main" ]; then
SYSTEM_PROMPT="Sen YouDown macOS uygulamasinin ARCHITECT Claude'usun (Ana Mac - Opus 4.6).
GOREVLERIN: Mac Mini kodunu review et, build sonucunu gor, hata varsa duzelt, build gecince [BUILD_OK] yaz, her sey bitince [TAMAMLANDI] yaz.
KOD FORMATI: ### Sources/YouTubeDownloader/Dosya.swift + \`\`\`swift blok \`\`\`
Swift 6 + SwiftUI, macOS 14+. Kisa teknik Turkce."
else
SYSTEM_PROMPT="Sen YouDown macOS uygulamasinin IMPLEMENTER Claude'usun (Mac Mini - Opus 4.6).
GOREVLERIN: Gorevi analiz et, Swift kodu yaz, review'lari dikkate al, [TAMAMLANDI] ile bitir.
KOD FORMATI: ### Sources/YouTubeDownloader/Dosya.swift + \`\`\`swift blok \`\`\`
Swift 6 + SwiftUI, macOS 14+. Kisa teknik Turkce."
fi

RUNNING=true
trap 'log "$MY_ROLE" "Durduruluyor..."; RUNNING=false' SIGINT SIGTERM

log "$MY_ROLE" "=== Autonomous Agent v2 (Opus 4.6) basladi ==="

IDLE_COUNT=0
MAX_IDLE=200

while $RUNNING; do
    touch_heartbeat "$MY_ROLE"
    check_conflicts || { sleep 10; continue; }
    check_seq_integrity || true

    if ! is_my_turn "$MY_ROLE"; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        [ $((IDLE_COUNT % 10)) -eq 0 ] && { check_peer_alive "$PEER_ROLE" 180 || true; }
        [ $IDLE_COUNT -ge $MAX_IDLE ] && { log "$MY_ROLE" "TIMEOUT."; break; }
        sleep "$POLL_INTERVAL"
        continue
    fi

    IDLE_COUNT=0
    log "$MY_ROLE" "Sira bende..."

    CONV=$(get_context 35000)
    LAST_SEQ=$(get_last_seq)
    FILES=""
    [ "$LAST_SEQ" -le 4 ] && { log "$MY_ROLE" "Proje dosyalari yukleniyor..."; FILES=$(read_project_files); }

    BUILD_SECTION=""
    if [ "$MY_ROLE" = "main" ]; then
        BUILD_OUT=$(run_build)
        BUILD_STATUS=$(printf '%s' "$BUILD_OUT" | head -1)
        BUILD_LOG=$(printf '%s' "$BUILD_OUT" | tail -n +2 | head -60)
        BUILD_SECTION="=== BUILD SONUCU ===
$BUILD_STATUS
$BUILD_LOG"
    fi

    PROMPT="$SYSTEM_PROMPT

=== PROJE DOSYALARI ===
$FILES

=== KONUSMA ===
$CONV

$BUILD_SECTION

Simdi senin siran:"

    log "$MY_ROLE" "Opus 4.6 cagriliyor..."
    REPLY=$(call_claude "$MY_ROLE" "$PROMPT") || { log "$MY_ROLE" "Claude basarisiz."; break; }

    if printf '%s' "$REPLY" | grep -q '```swift'; then
        log "$MY_ROLE" "Kodlar uygulanıyor..."
        apply_code_changes "$REPLY" | while read -r l; do log "$MY_ROLE" "$l"; done
    fi

    send_msg "$MY_ROLE" "$REPLY"
    log "$MY_ROLE" "Mesaj gonderildi ($(printf '%s' "$REPLY" | wc -c | tr -d ' ') chars)"

    printf '%s' "$REPLY" | grep -q '\[TAMAMLANDI\]' && { log "$MY_ROLE" "TAMAMLANDI!"; break; }

    sleep "$POLL_INTERVAL"
done

log "$MY_ROLE" "=== Agent durdu ==="
