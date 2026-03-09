# youdown-brain

**8 AI ajanin 4 ekip halinde otonom calistigi multi-agent pipeline sistemi.**

Claude instance'lari C+ Protocol ile kanal bazli JSON mesajlasma yapar. Gorev planlama, dagitim, kod yazma, QA testi ve deploy sureci tamamen otomatiktir.

---

## Mimari

```
                    ┌─────────────────────────────┐
                    │     ECE (Chief Architect)    │
                    │     Plan olusturur           │
                    └──────────┬──────────────────┘
                               │
                    ┌──────────▼──────────────────┐
                    │   CEYLiN (Orchestrator)      │
                    │   Gorevleri dagitir & takip   │
                    └──┬───────────┬──────────┬───┘
                       │           │          │
          ┌────────────▼──┐  ┌────▼───────┐  ┌▼─────────────┐
          │  TASARIM EKiBi │  │ BACKEND    │  │  QA / DEVOPS │
          │  ismail+zeynep │  │ hasan+saki │  │ ahmet+huseyin│
          │  kanal:tasarim │  │ kanal:back │  │  kanal: qa   │
          └───────────────┘  └────────────┘  └──────────────┘
```

### Ajanlar

| Ajan | Rol | Uzmanlık |
|------|-----|----------|
| **Ece** | Chief Architect | Mimari tasarim, plan olusturma, gorev kirilimi |
| **Ceylin** | Project Manager / Orchestrator | Gorev dagitimi, Dev↔QA dongusu, eskalasyon |
| **Ismail** | Senior Developer | Full-stack uygulama, Swift, React, Node.js |
| **Zeynep** | UX Architect | Design system, UI/UX, erisilebirlik |
| **Hasan** | Backend Architect | API tasarimi, veritabani, sistem mimarisi |
| **Saki** | Frontend Developer | React, CSS, component gelistirme |
| **Ahmet** | Reality Checker / QA | Test, kod inceleme, kalite kontrolu |
| **Huseyin** | DevOps Engineer | CI/CD, deploy, altyapi, monitoring |

### Ekipler ve Kanallar

| Ekip | Kanal | Uyeler |
|------|-------|--------|
| Orkestrasyon | `genel` | Ece, Ceylin |
| Tasarim | `tasarim` | Ismail, Zeynep |
| Backend | `backend` | Hasan, Saki |
| QA & DevOps | `qa` | Ahmet, Huseyin |

---

## Kurulum

### Gereksinimler

- **macOS** veya **Linux**
- **Python 3.6+**
- **Claude Code CLI** (`claude` komutu PATH'te olmali)
- **tmux** (panel gorunumu icin)

### Adimlar

```bash
# 1. Repo'yu klonla
git clone https://github.com/volkanyoruk/youdown-brain.git
cd youdown-brain

# 2. Calistirma izni ver
chmod +x *.sh lib/*.sh

# 3. Claude Code CLI'nin yuklu oldugunu dogrula
claude --version

# 4. (Opsiyonel) Model secimi
export CLAUDE_MODEL=claude-sonnet-4-6    # varsayilan
export CLAUDE_MODEL=claude-opus-4-6      # daha guclu, daha yavas
```

### Claude Code CLI Kurulumu

```bash
# npm ile
npm install -g @anthropic-ai/claude-code

# veya dogrudan
curl -fsSL https://claude.ai/install.sh | sh
```

---

## Kullanim

### Tek Komutla Tam Pipeline

```bash
./run_pipeline.sh "Login sayfasi ekle" --project /path/to/project
```

Bu komut sirasiyla:
1. Gorevi baslatir ve arsivler
2. Ece plan olusturur (mimari + gorev kirilimi)
3. Ceylin gorevleri ekiplere dagitir
4. Her developer gorevi yapar → QA test eder → PASS/FAIL
5. Basarisiz gorevler max 3 kez tekrarlanir, sonra eskale edilir

### Adim Adim Calistirma

```bash
# 1. Gorevi baslat
./start_task.sh "Dark mode destegi ekle" --project ~/projects/myapp

# 2. Ece plan olustursun
./youdown-brain.sh --role ece --mode pipeline --project ~/projects/myapp

# 3. Ceylin dagitsin ve yonetsin
./youdown-brain.sh --role ceylin --mode pipeline --project ~/projects/myapp

# 4. Worker daemon'lari baslat (ayri terminallerde)
./youdown-brain.sh --role ismail --mode worker --project ~/projects/myapp
./youdown-brain.sh --role hasan --mode worker --project ~/projects/myapp

# 5. QA daemon'u baslat
./youdown-brain.sh --role ahmet --mode qa --project ~/projects/myapp
```

### Web Dashboard (onerilen)

```bash
python3 dashboard.py
# Tarayicida ac: http://localhost:7777
```

Canli guncellenen web paneli:
- Pipeline durumu + ilerleme cubugu
- Tum kanal mesajlari renkli gorunum
- Ajan durumlari (canli/cevrimdisi)
- Handoff ve QA sonuclari
- QA istatistikleri
- Ajan loglari

Farkli port kullanmak icin: `python3 dashboard.py 8080`

### Terminal Paneli (tmux — alternatif)

```bash
./panel.sh
```

3 pencereli tmux oturumu acar:
- **Pencere 1:** Ece + Ceylin + Pipeline durumu
- **Pencere 2:** Ismail + Zeynep + Hasan + Saki (worker'lar)
- **Pencere 3:** Ahmet + Huseyin (QA & DevOps)

### Durum Kontrolu

```bash
./youdown-brain.sh --status
```

### Serbest Isbirligi Modu

```bash
# Iki ajan arasinda sira tabanli sohbet
./youdown-brain.sh --role ece --mode collab --project ~/projects/myapp
./youdown-brain.sh --role ismail --mode collab --project ~/projects/myapp
```

---

## C+ Protocol

Ajanlar arasi haberlesme altyapisi.

### Mesajlasma

- **Dosya formati:** `channels/<kanal>/NNN_role_timestamp.json`
- **Atomik yazma:** `tmp` dosyasina yaz → `mv` ile tasima (partial read onleme)
- **Sira numarasi:** Lock-based atomic seq (cakisma onleme)
- **Turn sistemi:** Son mesaji yazan bekler, karsi taraf cevaplar

### Mesaj Yapisi

```json
{
  "seq": 1,
  "from": "ece",
  "channel": "genel",
  "timestamp": 1773087423,
  "content": "Plan hazirlandi, 5 adimlik gorev...",
  "checksum": "3847291"
}
```

### Handoff Sistemi

Ekipler arasi gorev transferi:
```
Ceylin → Ismail: "Gorev #1: Login formu olustur"
Ismail tamamlar → Ceylin QA'ya gonderir
Ahmet test eder → PASS / FAIL
FAIL → max 3 tekrar → eskalasyon
```

### Kanal Yapisi

```
channels/
├── genel/       # Ece ↔ Ceylin
├── tasarim/     # Ismail ↔ Zeynep
├── backend/     # Hasan ↔ Saki
├── qa/          # Ahmet ↔ Huseyin
└── broadcast/   # Tum ekiplere duyuru
```

---

## Dosya Yapisi

```
youdown-brain/
├── youdown-brain.sh          # Ana brain — tum modlari yonetir
├── start_task.sh             # Yeni gorev baslat, eski mesajlari arsivle
├── run_pipeline.sh           # Tek komutla tam pipeline
├── dashboard.py              # Web dashboard (http://localhost:7777)
├── panel.sh                  # tmux ile 3 pencereli panel (alternatif)
│
├── lib/
│   ├── protocol.sh           # C+ Protocol core (mesaj, seq, turn, heartbeat)
│   ├── orchestrator.sh       # Ceylin'in gorev dagitim motoru
│   ├── qa_gate.sh            # Ahmet'in QA test motoru
│   ├── handoff.sh            # Ekipler arasi gorev transferi
│   ├── channel_watcher.sh    # Canli kanal mesaj gorunumu
│   ├── status_watcher.sh     # Pipeline ilerleme gorunumu
│   └── msg_watcher.sh        # Eski mesaj gorunumu (geriye uyumluluk)
│
├── agents/                   # Ajan kisilik tanimlari
│   ├── ece.md                # Chief Architect
│   ├── ceylin.md             # Orchestrator
│   ├── ismail.md             # Senior Developer
│   ├── zeynep.md             # UX Architect
│   ├── hasan.md              # Backend Architect
│   ├── saki.md               # Frontend Developer
│   ├── ahmet.md              # Reality Checker / QA
│   └── huseyin.md            # DevOps Engineer
│
├── teams/                    # Ekip tanimlari
│   ├── orkestrasyon.json     # Ece + Ceylin
│   ├── tasarim.json          # Ismail + Zeynep
│   ├── backend.json          # Hasan + Saki
│   └── qa.json               # Ahmet + Huseyin
│
├── channels/                 # (runtime) Kanal mesajlari
├── handoffs/                 # (runtime) Gorev transferleri + QA sonuclari
├── logs/                     # (runtime) Ajan loglari
└── archive/                  # (runtime) Arsivlenmis eski mesajlar
```

---

## Pipeline Akisi

```
1. PLANLAMA
   Kullanici gorev verir → start_task.sh
   Ece analiz eder → JSON plan olusturur
   Plan: gorev kirilimi + atamalar + bagimliliklar + kabul kriterleri

2. DAGITIM
   Ceylin plani alir → gorevleri ekiplere atar
   Bagimlilik sirasi: adim 1 bitmeden adim 2 baslamaz
   Paralel gorevler ayni anda dagitilir

3. UYGULAMA
   Developer gorevi alir → Claude ile kod yazar
   Kod ===FILE: path=== bloklari ile uygulanir
   Guvenlik: dosya yolu proje kokunden cikamaz

4. QA TESTI
   Ahmet kodu test eder (build + Claude analizi)
   PASS → gorev tamamlandi
   FAIL → developer'a geri gider (max 3 deneme)
   3 basarisiz deneme → Ceylin'e eskalasyon

5. TAMAMLANMA
   Tum adimlar PASS → pipeline bitti
   Ozet rapor + istatistikler
```

---

## Yapilandirma

### Ortam Degiskenleri

| Degisken | Varsayilan | Aciklama |
|----------|-----------|----------|
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Kullanilacak Claude modeli |
| `CLAUDE_BIN` | `claude` (PATH'ten) | Claude CLI binary yolu |
| `PROJECT_ROOT` | Repo ust dizini | Hedef proje dizini |
| `ACTIVE_CHANNEL` | `genel` | Varsayilan mesajlasma kanali |

### Ajan Ozellestirme

Her ajanin davranisi `agents/<isim>.md` dosyasiyla tanimlanir. YAML frontmatter + Markdown:

```yaml
---
name: ece
role: Chief Architect
expertise: [system-design, task-decomposition, architecture]
rules:
  - Asla kod yazma, sadece plan olustur
  - Her adima kabul kriterleri ekle
---

# Ece — Chief Architect

Sen bir yazilim mimarisisin...
```

### Yeni Ekip Ekleme

`teams/` altina JSON dosyasi ekleyin:

```json
{
  "name": "Mobile",
  "channel": "mobile",
  "members": ["ali", "veli"],
  "focus": "iOS ve Android gelistirme"
}
```

Sonra `agents/ali.md` ve `agents/veli.md` tanimlarini olusturun.

---

## Guvenlik

- **Dosya yolu dogrulamasi:** `apply_code_changes()` proje kokunden cikmaya izin vermez
- **Atomik yazma:** Partial read / corrupt JSON onlenir
- **Env var gecisi:** Shell→Python arasi veri aktariminda string interpolation yerine `os.environ` kullanilir
- **Lock mekanizmasi:** Seq numarasi ve handoff icin `mkdir` tabanli lock
- **Pipefail guvenli:** Tum scriptler `set -euo pipefail` altinda test edilmistir

---

## Lisans

MIT
