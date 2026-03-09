# youdown-brain

**Akilli multi-agent pipeline. 8 ajan, 4 ekip, otomatik gorev yonlendirme.**

Gorev karmasikligini analiz eder, gereken minimum ajan sayisini secer, prompt caching ile token tasarrufu yapar, bagimsiz gorevleri paralel calistirir.

```
Basit soru   →  1 ajan      ~2K token    "React hook nasil yazilir?"
Orta gorev   →  dev + QA    ~5K token    "Bu fonksiyonu duzelt"
Ekip isi     →  2-3 ajan    ~12K token   "UI tasarimini yenile"
Buyuk proje  →  8 ajan      ~23K token   "Kullanici yonetim sistemi ekle"
```

---

## Hizli Baslangic

```bash
git clone https://github.com/volkanyoruk/youdown-brain.git
cd youdown-brain

pip install -r requirements.txt
export ANTHROPIC_API_KEY='sk-ant-...'

python3 brain.py "Login sayfasi ekle" --project ~/myapp
```

---

## Kullanim

### Gorev Calistirma

```bash
# Otomatik strateji — sistem karmasikligi analiz eder
python3 brain.py "Login sayfasi ekle" --project ~/myapp

# Belirli bir ajan kullan
python3 brain.py "Bu kodu acikla" --agent ece

# Stratejiyi zorla
python3 brain.py "Gorev" --strategy single     # Tek ajan
python3 brain.py "Gorev" --strategy pair        # Developer + QA
python3 brain.py "Gorev" --strategy team        # Ekip
python3 brain.py "Gorev" --strategy full        # Tam pipeline

# Model degistir
python3 brain.py "Gorev" --model claude-opus-4-6
```

### Web Dashboard

```bash
python3 brain.py --dashboard                    # http://localhost:7777
python3 brain.py --dashboard --port 8080        # Farkli port
```

Dashboard ozellikleri:
- Gorev gonderme formu (strateji secimi dahil)
- WebSocket ile anlik canli akis
- Token kullanimi (input, cache hit, output, maliyet orani)
- Pipeline ilerleme cubugu ve adim detaylari
- Ajan aktivite takibi

---

## Nasil Calisiyor

### 1. Akilli Yonlendirme (router.py)

Gorev gelir → heuristik analiz + Haiku siniflandirma → minimum strateji secilir.

```
"React hook nasil yazilir?"     →  SINGLE  (1 cagri, ~2K token)
"Login fonksiyonunu duzelt"     →  PAIR    (dev + QA, ~5K token)
"UI tasarimini komple yenile"   →  TEAM    (2-3 ajan, ~12K token)
"E-ticaret sistemi kur"        →  FULL    (plan + dagit + QA, ~23K token)
```

Ajan eslestirme:

| Anahtar kelimeler | Ajan |
|-------------------|------|
| mimar, plan, strateji | Ece |
| yaz, implement, gelistir, duzelt | Ismail |
| ui, ux, tasarim, tema, renk | Zeynep |
| api, endpoint, database, backend | Hasan |
| component, frontend, react, css | Saki |
| test, review, kontrol, kalite | Ahmet |
| deploy, docker, ci/cd, nginx | Huseyin |

### 2. Prompt Caching (engine.py)

Anthropic API `cache_control` ile:

```
Ilk cagri:  Ajan prompt (300 tok) + Proje (4000 tok) = 4300 tok (tam fiyat)
Sonraki:    Ayni prompt cached = 430 tok (0.1x fiyat)
```

16 cagrilik bir pipeline'da: **62,000 token tasarruf** (~%70).

Multi-turn: Ayni ajan tekrar cagirildiginda onceki konusma hatirlanir — context tekrar gonderilmez.

### 3. Paralel Calisma (pipeline.py)

Topolojik siralama ile bagimsiz gorevler ayni anda calisir:

```
Ece plan:  [Adim1, Adim2, Adim3(dep:1,2), Adim4(dep:3)]

Seviye 1:  Adim1 + Adim2  (paralel)
Seviye 2:  Adim3          (1,2 bitmesini bekler)
Seviye 3:  Adim4          (3 bitmesini bekler)
```

Sirayla: 4 tur × ortalama 30sn = 120sn
Paralel: 3 tur × ortalama 30sn = 90sn (+ 2 gorev paralel)

### 4. Dev-QA Dongusu

```
Developer kodu yazar
    ↓
Ahmet (QA) test eder
    ↓
PASS → sonraki gorev
FAIL → developer'a geri bildirim (multi-turn, context korunur)
    ↓
Max 3 deneme → eskalasyon
```

QA multi-turn avantaji: Geri bildirim → duzeltme dongusunde proje dosyalari tekrar gonderilmez. Sadece "su sorunlari duzelt" mesaji gider.

---

## Mimari

```
                 ┌──────────────────────────────────┐
                 │          brain.py                 │
                 │   CLI giris noktasi               │
                 └──────────┬───────────────────────┘
                            │
              ┌─────────────▼─────────────┐
              │        router.py          │
              │  SINGLE / PAIR / TEAM /   │
              │  FULL strateji secimi     │
              └─────────────┬─────────────┘
                            │
              ┌─────────────▼─────────────┐
              │       pipeline.py         │
              │  Paralel orchestration    │
              │  Dev-QA loop              │
              └─────────────┬─────────────┘
                            │
              ┌─────────────▼─────────────┐
              │        engine.py          │
              │  Anthropic API            │
              │  Prompt caching           │
              │  Multi-turn session       │
              └───────────────────────────┘
```

### Ajanlar

| Ajan | Rol | Ekip |
|------|-----|------|
| **Ece** | Chief Architect — plan olusturur, kod yazmaz | Orkestrasyon |
| **Ceylin** | Orchestrator — dagitir, takip eder | Orkestrasyon |
| **Ismail** | Senior Developer — fullstack implementasyon | Tasarim |
| **Zeynep** | UX Architect — UI/UX, design system | Tasarim |
| **Hasan** | Backend Architect — API, database | Backend |
| **Saki** | Frontend Developer — React, CSS | Backend |
| **Ahmet** | QA / Reality Checker — test, kalite kapisi | QA & DevOps |
| **Huseyin** | DevOps Engineer — deploy, altyapi | QA & DevOps |

### Stratejiler Detay

**SINGLE** — Tek ajan, tek cagri.
Soru, aciklama, review talebi. En uygun ajan otomatik secilir.

**PAIR** — Developer + QA.
Developer kodu yazar → Ahmet test eder. Basit bug fix, tek dosya degisikligi.

**TEAM** — Ayni ekipten 2-3 ajan paralel.
Ornk: Zeynep (UI tasarim) + Saki (frontend) ayni anda calisir → Ahmet onaylar.

**FULL** — Tam pipeline.
Ece plan yapar → bagimsiz gorevler paralel dagitilir → her biri QA'dan gecer → max 3 retry → eskalasyon.

---

## Dosya Yapisi

```
youdown-brain/
├── brain.py              # Ana giris noktasi — CLI + strateji dispatch
├── engine.py             # Anthropic API client — caching + session + token tracking
├── router.py             # Akilli yonlendirme — heuristik + Haiku siniflandirma
├── pipeline.py           # Paralel pipeline — topo sort + dev-qa loop
├── dashboard_v2.py       # Web dashboard — WebSocket + gorev gonderme
├── requirements.txt      # anthropic, aiohttp, aiosqlite
│
├── agents/               # Ajan kisilik tanimlari (Markdown + YAML frontmatter)
│   ├── ece.md            # Chief Architect
│   ├── ceylin.md         # Orchestrator
│   ├── ismail.md         # Senior Developer
│   ├── zeynep.md         # UX Architect
│   ├── hasan.md          # Backend Architect
│   ├── saki.md           # Frontend Developer
│   ├── ahmet.md          # Reality Checker / QA
│   └── huseyin.md        # DevOps Engineer
│
├── teams/                # Ekip tanimlari
│   ├── orkestrasyon.json
│   ├── tasarim.json
│   ├── backend.json
│   └── qa.json
│
└── data/                 # (runtime) Pipeline state
```

---

## Yapilandirma

### Ortam Degiskenleri

| Degisken | Varsayilan | Aciklama |
|----------|-----------|----------|
| `ANTHROPIC_API_KEY` | (gerekli) | Anthropic API anahtari |
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Model secimi |

### Ajan Ozellestirme

`agents/<isim>.md` dosyasini duzenleyin:

```yaml
---
name: ece
role: chief-architect
---

# Ece — Bas Mimar

Sen Ece, projelerin bas mimarisin...
```

### Yeni Ajan / Ekip Ekleme

1. `agents/yeni_ajan.md` olustur
2. `teams/yeni_ekip.json` olustur:
```json
{
  "name": "Mobile",
  "channel": "mobile",
  "members": ["yeni_ajan"]
}
```
3. `router.py` KEYWORD_MAP'e ajan anahtar kelimelerini ekle

---

## Token Karsilastirma

| Senaryo | Geleneksel (tek Claude oturumu) | v2 (bash pipeline) | v3 (smart) |
|---------|------|------|------|
| Basit soru | ~2K | ~8K (gereksiz overhead) | ~2K |
| 5 adimli gorev | ~15K | ~76K (cache yok) | ~23K |
| 10 adimli proje | ~30K | ~150K+ | ~40K |

v3 avantaji: Basit isler icin tek Claude oturumu kadar verimli, karmasik isler icin paralel calisma + QA kalite kapisi.

---

## Guvenlik

- **Path traversal koruması**: `apply_code_changes()` dosya yolunu `resolve()` ile kontrol eder, proje kokunden cikamaz
- **Prompt caching**: Hassas veri cache'te 5dk sonra silinir (Anthropic ephemeral cache)
- **API key**: Sadece ortam degiskeni uzerinden, koda yazilmaz

---

## Lisans

MIT
