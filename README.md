# youdown-brain

**İki Claude instance'ının birbirleriyle ve kullanıcıyla otonom iletişim kurduğu çok-ajan sistemi.**

Ana Mac ve Mac Mini'deki iki ayrı Claude, paylaşımlı dosyalar (Syncthing) üzerinden C+ Protocol ile haberleşir. Kullanıcı araya girmeden kodlama görevlerini birlikte tamamlayabilirler.

---

## Mimari

```
Ana Mac (Architect Claude)  ←──── Syncthing ────→  Mac Mini (Implementer Claude)
        │                         messages/*.json          │
        └──── ask_mini.sh ──→ ask_mini.txt ──→ youdown-brain --mode qa
```

**C+ Protocol:** Atomik JSON mesajları, seq numaraları, heartbeat, conflict detection.

---

## Dosya Yapısı

```
youdown-brain/
├── youdown-brain.sh   # Ana brain — 3 mod: qa | collab | auto
├── ask_mini.sh        # Kullanıcı/Ana Mac → Mini'ye anlık soru
├── start_task.sh      # Yeni işbirliği görevi başlat
├── agent.sh           # Otonom agent v2
└── lib/
    └── protocol.sh    # C+ Protocol core (atomic writes, retry, heartbeat)
```

---

## Kurulum

1. Syncthing ile iki Mac arasında bu klasörü senkronize et
2. Her iki makinede `~/.local/bin/claude` kurulu olmalı (Claude Code CLI)
3. Çalıştırma izni: `chmod +x *.sh`

---

## Kullanım

### QA Modu — Mini her zaman hazır bekler, anlık soru yanıtlar

**Mac Mini'de:**
```bash
./youdown-brain.sh --role mini --mode qa
```

**Ana Mac'ten soru sormak için:**
```bash
./ask_mini.sh "Swift 6'da async stream nasıl kullanılır?"
```

### Collab Modu — Sıra tabanlı işbirliği

**Görev başlat:**
```bash
./start_task.sh "Dark mode özelliği ekle" --initiator main
```

**Her iki makinede:**
```bash
./youdown-brain.sh --role main --mode collab
./youdown-brain.sh --role mini --mode collab
```

### Auto Modu — Tam otonom (build + kod yazma)

```bash
./youdown-brain.sh --role main --mode auto
./youdown-brain.sh --role mini --mode auto
```

---

## Model Seçimi

```bash
export CLAUDE_MODEL=claude-opus-4-6  # default
export CLAUDE_BIN=/path/to/claude    # default: ~/.local/bin/claude
```

---

## C+ Protocol

- **Mesajlar:** `messages/NNN_role_timestamp.json` (atomic write: tmp → mv)
- **Sıra:** Son mesajı kimin yazdığına göre turn check
- **Retry:** 3 deneme, 5/15/30s exponential backoff
- **Heartbeat:** `.heartbeat_main` / `.heartbeat_mini` dosyaları
- **Conflict:** Syncthing çakışması otomatik algılanır
