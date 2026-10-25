---
name: webhook-mode-auto-on-instabox
version: 1.0.0
author: slamsmart
description: "Bot Telegram instabox diam sampai VPS di-start manual? Pakai webhook mode: POST dari Telegram otomatis membangunkan mesin yang idle-pause, hemat run budget, tanpa polling. Triggers: bot telegram diem, bangunin vps, auto-on instabox, webhook hermes, setWebhook, TELEGRAM_WEBHOOK_URL, gateway polling, idle pause, bot tidak merespons, 502 port publik, 503 sandbox, sandbox instabox sleep."
---

# Webhook Mode Auto-on Instabox.sh — skill untuk agent

Memberi sandbox instabox (Firecracker VM) kemampuan **bangun sendiri saat ada chat**, tanpa
polling dan tanpa menyentuh tombol "start" di dashboard.

## Kapan dipakai

- Bot Telegram (Hermes gateway) hanya hidup kalau VPS di-start manual.
- Gateway masih **long polling** padahal mesin sudah punya port publik.
- URL publik bot balas **502** (tidak ada yang listen) atau **503** (mesin mati/pause manual).
- Memasang bot baru atau bot kedua di mesin yang sama.
- Ingin menghemat run budget: biarkan mesin idle-pause, bangun hanya saat ada pesan.

## Kenapa webhook bisa membangunkan mesin

| Fakta | Konsekuensi |
|---|---|
| Instabox men-*pause* mesin setelah **30 menit idle** (default, fixed kecuali akun punya `manualLifecycle`) | Mesin tidur sendiri — irit kuota |
| **Kunjungan ke URL port publik me-resume mesin** dan request-nya ditahan sampai mesin siap | HTTP push apa pun = sinyal bangun |
| Telegram **webhook** mengirim update via POST ke URL kita | Pesan masuk = mesin bangun, bot langsung memproses |
| **Long polling** arahnya terbalik (bot menanya Telegram) | Saat mesin pause tidak ada yang menanya → bot bisu |

Jadi: polling tidak punya cara membangunkan diri sendiri, webhook punya. Balasan pertama
setelah idle terasa 5–15 detik (resume + boot) — itu **bukti mesin sedang hemat**, bukan bug.

## Setup cepat

Dari komputer kamu (script butuh CLI `instabox` yang **tidak terpasang di dalam sandbox**):

```bash
git clone https://github.com/slamsmart/webhook-mode-auto-on-instabox.sh.git
cd webhook-mode-auto-on-instabox.sh
chmod +x setup-webhook.sh
./setup-webhook.sh <machine-id-atau-nama>
```

Langkah manual (ringkas) — detail di README repo:

1. Publish port: `instabox-port publish 8443 --name hermes-telegram-webhook --json` (di dalam mesin) atau `POST /v1/machines/{id}/ports` (API).
2. Tulis ke `~/.hermes/.env` (rahasia selalu di `.env`, bukan `config.yaml`) — port default adapter 8443:
   ```
   TELEGRAM_WEBHOOK_URL=https://8443-<id-tanpa-m_>.instabox.tech/telegram
   TELEGRAM_WEBHOOK_SECRET=$(openssl rand -hex 32)
   TELEGRAM_WEBHOOK_PORT=8443
   ```
3. `hermes config set platforms.telegram.extra.drop_pending_on_cold_boot false` — supaya pesan pertama yang membangunkan tidak dibuang.
4. Restart gateway **dari shell terpisah** (dari dalam sesi chat gateway memblokir restart-nya sendiri): `hermes gateway restart`, atau `instabox stop <id> && instabox start <id>`.
5. Adapter Hermes mendaftarkan webhook ke Telegram sendiri saat start (termasuk `secret_token`). Kalau perlu manual: `POST https://api.telegram.org/bot<token>/setWebhook` dengan `url` + `secret_token`.

## Verifikasi — 4 lapis, jangan berhenti di lapis 1

```bash
# 1) Di dalam mesin: server benar-benar listen?
ss -tlnp | grep 8443                                  # harus ada PID hermes di 0.0.0.0
systemctl --user is-active hermes-gateway.service      # active
grep -E "Webhook server listening|webhook mode" ~/.hermes/logs/gateway.log | tail -2
#    → "Webhook server listening on * (all interfaces, IPv4+IPv6):8443/telegram"
#    → "Connected to Telegram (webhook mode)"

# 2) Dari sisi Telegram: status registrasi
curl -s "https://api.telegram.org/bot$TOKEN/getWebhookInfo" \
  | jq '.result | {url, pending_update_count, last_error_message}'
#    → url benar, pending 0, last_error null

# 3) Dari luar mesin: server webhook hidup? (bisa dijalankan dari mesin lain)
curl -s -o /dev/null -w '%{http_code}\n' https://8443-<id>.instabox.tech/telegram
#    → 405 = webhook server hidup (menolak GET, hanya terima POST)
#    → 502 = port dipublish TAPI tidak ada yang listen (gateway masih polling / mati)
#    → 503 = mesin dijeda/di-stop manual (tidak akan bangun sendiri)

# 4) End-to-end: kirim satu pesan ke bot, lalu cek
grep "inbound message" ~/.hermes/logs/gateway.log | tail -1
curl -s "https://api.telegram.org/bot$TOKEN/getWebhookInfo" | jq '.result.pending_update_count'
#    → log masuk + pending balik 0 = jalur webhook → agent benar-benar jalan
```

## Pitfalls (inilah yang bikin 90% kegagalan)

- **URL balas 502.** Paling sering: `.env` sudah diisi tapi **gateway belum di-restart**, jadi masih polling dan tidak ada yang listen di 8443. Restart service, cek ulang.
- **`Conflict: terminated by setWebhook request`** di log = masih ada poller lama yang berebut dengan webhook. Restart gateway. Dua gateway berbeda **tidak bisa** polling dengan token bot yang sama.
- **Mesin yang di-stop atau di-pause manual TIDAK bangun saat dikunjungi.** Hanya *idle auto-pause* yang bisa dibangunkan trafik; yang lain harus `start`/`resume` dulu. Jadi biasakan **jangan stop manual** — biarkan idle-pause yang bekerja.
- **`TELEGRAM_WEBHOOK_SECRET` wajib.** Tanpa itu adapter menolak start di mode webhook.
- **Autostart setelah mesin start:** `systemctl --user` unit `hermes-gateway.service` harus `enabled` **dan** akun punya `Linger=yes`, kalau tidak gateway tidak naik sendiri setelah stop→start (pernah kejadian: mesin hidup tapi bot tetap diem).
- **Plan free (default instabox):** idle pause 1800 detik (fixed, tanpa `manualLifecycle` tidak bisa diubah lewat API — PATCH-nya dibalas dengan nilai efektif), dan `maxRunMinutes: 480`. Setelah 8 jam berjalan, mesin **pause + cooldown ~10 menit**; selama cooldown **semua jalur wake ditolak** dengan `409 machine_cooldown` + `Retry-After`. Lewat cooldown, pesan berikutnya membangunkan lagi.
- **Resume me-reset jam max-run** (`runStartedAt` diisi ulang). Jadi selagi bot sempat idle-pause di antaranya, kuota 8 jam tidak habis-habis.
- **Jangan pasang cron keepalive** bareng webhook — itu membatalkan penghematannya.
- **CLI `instabox` tidak tersedia di dalam sandbox.** Kalau harus bekerja dari dalam mesin, pakai HTTP API: `https://api.instabox.sh/v1/...` + header `X-API-Key` — endpoint berguna: `GET /machines`, `GET /machines/{id}`, `POST /machines/{id}/ports`, `POST /machines/{id}/exec` (`{"cmd":..., "timeoutSeconds":...}`), `POST /machines/{id}/start`.
- **URL port itu publik.** Siapa pun yang tahu URL-nya bisa memanggil service; secret token adalah satu-satunya gerbang. Pakai hex acak 32 byte, dan jangan taruh token di repo.
- **Satu bot satu port.** Bot kedua di mesin yang sama pakai `TELEGRAM_WEBHOOK_PORT` + port publish berbeda (mis. 8444).

## Troubleshooting

| Gejala | Penyebab paling mungkin | Aksi |
|---|---|---|
| Bot bisu, URL 502 | Gateway masih polling / mati | `systemctl --user restart hermes-gateway.service`, cek log |
| Bot bisu, URL 405 tapi tak ada balasan | `getWebhookInfo` ada `last_error` (URL/secret salah) | Perbaiki `.env` → restart → `setWebhook` ulang |
| `pending_update_count` naik terus | Mesin dipause manual / cooldown max-run | `start`/`resume`, atau tunggu cooldown lewat |
| Balasan pertama lambat, seterusnya cepat | Normal — mesin baru resume | Tidak ada yang perlu diperbaiki |
| `Conflict: terminated by setWebhook request` | Poller lama masih hidup | Restart gateway; pastikan hanya satu gateway per token |
| Mesin hidup tapi bot tetap diem | Unit systemd tidak enabled / tanpa linger | `systemctl --user enable --now hermes-gateway.service`, cek `loginctl show-user $USER \| grep Linger` |
| Sudah 8 jam lalu mati ~10 menit | Limit plan free (`maxRunMinutes 480` + cooldown) | Tunggu cooldown, pesan berikutnya bangunkan sendiri; naik plan untuk `-1` (tanpa batas) |

## Kembali ke polling

```bash
curl -s -X POST "https://api.telegram.org/bot$TOKEN/deleteWebhook"
# hapus TELEGRAM_WEBHOOK_URL (dan SECRET/PORT) dari ~/.hermes/.env
# restart gateway
```

## Quick reference

```bash
instabox-port publish 8443 --name hermes-telegram-webhook --json   # publish port
instabox-port list                                                  # daftar port
instabox-port unpublish 8443                                        # tutup port
ss -tlnp | grep 8443                                                # listener di dalam mesin
curl -s -o /dev/null -w '%{http_code}\n' https://8443-<id>.instabox.tech/telegram   # 405 sehat
curl -s "https://api.telegram.org/bot$TOKEN/getWebhookInfo" | jq .result
curl -s -X POST "https://api.telegram.org/bot$TOKEN/deleteWebhook"
```

---

Dibuat oleh @slamsmart • Powered by Hermes Agent & Instabox
