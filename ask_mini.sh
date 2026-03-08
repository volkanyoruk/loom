#!/bin/bash
# Ece'den Ceylin'e soru sor — cevabı stdout'a yazar
# Kullanım: bash ask_mini.sh "sorun burada"

AGENTS="$(cd "$(dirname "$0")" && pwd)"
INBOX="$AGENTS/ask_ceylin.txt"
OUTBOX="$AGENTS/ceylin_reply.txt"
BUSY="$AGENTS/.ceylin_busy"
TIMEOUT=120

QUESTION="$*"
[ -z "$QUESTION" ] && echo "Kullanım: $0 \"soru\"" && exit 1

# Outbox temizle, soruyu gönder
rm -f "$OUTBOX"
printf '%s' "$QUESTION" > "$INBOX"

# Cevap bekle
WAITED=0
printf "⏳ Ceylin düşünüyor" >&2
while [ ! -f "$OUTBOX" ] || [ -f "$BUSY" ]; do
    sleep 1
    WAITED=$((WAITED + 1))
    printf "." >&2
    [ $WAITED -ge $TIMEOUT ] && echo "" && echo "[TIMEOUT: $TIMEOUT sn]" && exit 1
done

echo "" >&2
cat "$OUTBOX"
rm -f "$OUTBOX"
