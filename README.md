# Webhook Mode Auto-on Instabox.sh

Bangunin bot Telegram kamu secara otomatis pas VPS instabox lagi tidur — tanpa perlu polling, tanpa buang kuota run budget.

> **Untuk agent / LLM:** pakai [`SKILL.md`](./SKILL.md) — versi instruksi yang bisa langsung dimuat (frontmatter + langkah verifikasi + pitfalls). README ini untuk manusia.

## Masalah

Instabox sandbox punya fitur **idle auto-suspend**: kalau 30 menit nggak ada aktivitas, mesinnya pause otomatis. Masalahnya, Hermes Agent gateway pake **long polling** secara default — bot nanya ke Telegram tiap beberapa detik "ada pesan baru?". Begitu mesin pause, polling berhenti, dan bot jadi **bisu**. Pesan yang dikirim ke bot hilang tanpa dibaca.

## Solusi: Webhook Mode

**Webhook** balikkan arahnya: Telegram yang push pesan ke URL publik sandbox kamu. HTTP push ini otomatis **membangunkan** mesin yang sedang pause, jadi bot selalu lihat pesannya.

| Mode | Cara Kerja | Dampak ke Run Budget |
|------|-----------|---------------------|
| **Polling** (default) | Bot nanya Telegram tiap ~2 detik | Dianggap aktivitas — reset idle timer |
| **Webhook** ✅ | Telegram hubungi URL kamu cuma pas ada pesan | Hanya bangun pas ada chat — hemat budget |

Balasan pertama setelah idle agak lebih lambat (~5-15 detik untuk resume + boot). **Keterlambatan itu justru fitur** — artinya mesin sedang pause dan menghemat kuota.

## Cara Pakai

### 1. Clone repo

```bash
git clone https://github.com/slamsmart/webhook-mode-auto-on-instabox.sh.git
cd webhook-mode-auto-on-instabox.sh
```

### 2. Jalankan script setup

```bash
chmod +x setup-webhook.sh
./setup-webhook.sh <machine-id>
```

Atau lakukan manual:

### 3. Publish port

```bash
instabox-port publish 8443 --name hermes-telegram-webhook --json
```

Simpan URL yang didapat, contoh: `https://8443-<machine-id>.instabox.tech`

### 4. Tambah konfigurasi ke `~/.hermes/.env`

```bash
SECRET=$(openssl rand -hex 32)
cat >> ~/.hermes/.env << EOF

TELEGRAM_WEBHOOK_URL=https://8443-<machine-id>.instabox.tech/telegram
TELEGRAM_WEBHOOK_SECRET=$SECRET
TELEGRAM_WEBHOOK_PORT=8443
EOF
```

### 5. Nonaktifkan `drop_pending_on_cold_boot`

```bash
hermes config set platforms.telegram.extra.drop_pending_on_cold_boot false
```

Ini penting biar pesan pertama yang membangunkan mesin **tidak dibuang**.

### 6. Daftarkan webhook ke Telegram API

```bash
TOKEN=$(grep TELEGRAM_BOT_TOKEN ~/.hermes/.env | cut -d= -f2)
SECRET=$(grep TELEGRAM_WEBHOOK_SECRET ~/.hermes/.env | cut -d= -f2)
URL=$(grep TELEGRAM_WEBHOOK_URL ~/.hermes/.env | cut -d= -f2)

curl -s -X POST "https://api.telegram.org/bot${TOKEN}/setWebhook" \
  --data-urlencode "url=${URL}" \
  --data-urlencode "secret_token=${SECRET}"
```

Respon yang diharapkan: `{"ok": true, "description": "Webhook was set"}`

### 7. Restart gateway

```bash
hermes gateway restart
```

> **Catatan:** Kalau kamu menjalankan perintah ini dari dalam sesi Hermes (seperti chat ini), gateway akan memblokirnya. Buka terminal terpisah, atau restart seluruh sandbox:
> ```bash
> instabox stop <machine-id> && instabox start <machine-id>
> ```

### 8. Verifikasi

```bash
# Cek dari sisi Telegram
curl -s "https://api.telegram.org/bot${TOKEN}/getWebhookInfo" | jq '.result | {url, pending_update_count, last_error_message}'

# Cek log gateway
tail -20 ~/.hermes/logs/gateway.log | grep -i "telegram\|webhook"
```

## Kembali ke Polling

```bash
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/deleteWebhook"
# Hapus TELEGRAM_WEBHOOK_URL dari .env
# Restart gateway
```

Polling jadi mode default kalau `TELEGRAM_WEBHOOK_URL` tidak diset.

## Yang Perlu Diketahui

| Skenario | Yang Terjadi |
|----------|-------------|
| Mesin aktif, kamu kirim pesan | Balasan langsung (sama kayak polling) |
| Mesin idle-pause, kamu kirim pesan | Balasan pertama agak lambat (~5-15 dtk), sisanya normal |
| Mesin distop (bukan pause) | 503 dari URL publik — start manual dulu |
| Budget run habis (plan free: `maxRunMinutes` 480) | Mesin pause + **cooldown ~10 menit**; selama cooldown semua jalur wake ditolak (`409 machine_cooldown` + `Retry-After`). Setelah cooldown lewat, **pesan berikutnya membangunkan mesin lagi** (tidak perlu start manual). Resume juga me-reset jam max-run, jadi jendela 8 jam mulai dari nol lagi |
| Orang iseng nemu URL webhook kamu | Tanpa secret token, Telegram tolak POST-nya sebelum sampai ke gateway |

## Cek Sehat Cepat — bedakan tiap kode HTTP

Jalankan dari mesin lain (atau dari dalam mesin sendiri):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://8443-<machine-id>.instabox.tech/telegram
```

| Kode | Artinya | Aksi |
|------|---------|------|
| **405** | ✅ Webhook server hidup (menolak GET, cuma terima POST) | Normal, tidak ada yang perlu diperbaiki |
| **502** | Port dipublish, tapi **tidak ada yang listen** — gateway masih long polling atau mati | Restart gateway: `systemctl --user restart hermes-gateway.service`, lalu cek log |
| **503** | Mesin di-pause/di-stop **manual** → tidak akan bangun sendiri | `start`/`resume` mesin; hanya idle auto-pause yang bangun saat dikunjungi |

Cek dari sisi Telegram & dari dalam mesin:

```bash
# status registrasi webhook
curl -s "https://api.telegram.org/bot${TOKEN}/getWebhookInfo" \
  | jq '.result | {url, pending_update_count, last_error_message}'
#    → url benar, pending 0, last_error null

# listener & mode gateway di dalam mesin
ss -tlnp | grep 8443
grep -E "Webhook server listening|webhook mode" ~/.hermes/logs/gateway.log | tail -2
```

## Pitfalls

- **Secret token WAJIB.** Tanpa `TELEGRAM_WEBHOOK_SECRET` gateway menolak start di mode webhook (security: GHSA-3vpc-7q5r-276h).
- **URL port itu publik.** Secret token adalah satu-satunya pelindung — pakai random hex string yang kuat.
- **Satu port per mesin.** Kalau mau pasang bot kedua di mesin yang sama, pakai port beda (misal 8444).
- **Webhook vs cron heartbeat.** Jangan pasang keepalive cron barengan webhook — webhook sudah otomatis bangunin mesin pas ada chat.
- **Gateway harus autostart.** Unit `hermes-gateway.service` (systemd user) wajib `enabled` **dan** akun punya `Linger=yes`; kalau tidak, mesin hidup setelah start tapi bot tetap bisu. Cek: `systemctl --user is-enabled hermes-gateway.service` dan `loginctl show-user $USER | grep Linger`.
- **CLI `instabox` tidak ada di dalam sandbox.** Kalau harus bekerja dari dalam mesin, pakai HTTP API: `https://api.instabox.sh/v1/...` + header `X-API-Key` (`/machines`, `/machines/{id}/ports`, `/machines/{id}/exec`, `/machines/{id}/start`).

## Quick Reference

```bash
# Publish port
instabox-port publish 8443 --name my-webhook --json

# Lihat daftar port
instabox-port list

# Hapus port
instabox-port unpublish 8443

# Cek status webhook (dari Telegram)
curl -s "https://api.telegram.org/bot${TOKEN}/getWebhookInfo" | jq .

# Cek sehat: 405 = webhook hidup, 502 = belum listen, 503 = mesin stop/pause manual
curl -s -o /dev/null -w '%{http_code}\n' https://8443-<machine-id>.instabox.tech/telegram

# Hapus webhook
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/deleteWebhook"
```

## State Mesin

| `state` | Bisa dibangunin webhook? |
|---------|--------------------------|
| `running` | ✅ Ya — gateway siap melayani |
| `paused` | ✅ Ya — HTTP masuk otomatis bangunin |
| `stopped` | ❌ Tidak — harus start manual |

Hanya **idle auto-suspend (paused)** yang bisa dibangunin oleh incoming webhook.

---

Dibuat oleh @slamsmart • Powered by Hermes Agent & Instabox