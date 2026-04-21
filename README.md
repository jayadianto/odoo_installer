# Odoo Deployment Tool

Deploy Odoo 15-19 ke server Ubuntu dari Mac/Linux lokal via SSH.

## Fitur

- ✅ Support **Odoo 15, 16, 17, 18, 19** (Community & Enterprise)
- ✅ **Python Virtual Environment** — tidak menggunakan system pip
- ✅ **PostgreSQL 16** + **PgBouncer** (connection pooling)
- ✅ **Nginx** reverse proxy + virtual host
- ✅ **Cloudflare SSL** (wildcard/general certificate per root domain)
- ✅ **Auto-update DNS Cloudflare** (A Record / CNAME via API)
- ✅ **Systemd service** — modern service management
- ✅ **Deploy dari lokal** — jalankan di Mac, otomatis SSH ke server

## Struktur Folder

```
vitraining/
├── deploy.sh              # Script deploy (jalankan dari Mac)
├── odoo_install.sh        # Script install (dijalankan di server)
├── ssl/                   # Folder SSL certificate
│   ├── cloudflare_origin.pem   # Cloudflare Origin Certificate
│   └── cloudflare_origin.key   # Cloudflare Private Key
└── README.md
```

## Persiapan

### 1. SSH Key

Pastikan Anda memiliki SSH key yang sudah terdaftar di server target:

```bash
# Jika belum punya SSH key
ssh-keygen -t rsa -b 4096

# Copy key ke server
ssh-copy-id -i ~/.ssh/id_rsa root@IP_SERVER
```

Atau jika menggunakan key dari cloud provider (seperti Alibaba Cloud `.pem`):

```bash
# Pastikan permission benar
chmod 600 ~/.ssh/your_key.pem

# Test koneksi
ssh -i ~/.ssh/your_key.pem root@IP_SERVER
```

### 2. SSL Certificate (Cloudflare)

Letakkan file SSL certificate dari Cloudflare di folder `ssl/`:

1. Buka **Cloudflare Dashboard** → Domain Anda
2. **SSL/TLS** → **Origin Server** → **Create Certificate**
3. Pilih wildcard (`*.yourdomain.com`) agar bisa dipakai untuk semua subdomain
4. Download/copy **Origin Certificate** → simpan sebagai `ssl/cloudflare_origin.pem`
5. Download/copy **Private Key** → simpan sebagai `ssl/cloudflare_origin.key`

> ⚠️ **Penting**: File SSL bersifat **wildcard per root domain**. Misal:
> - Domain `erp.xerpium.com` → pakai cert dari `xerpium.com`
> - Domain `test.xerpium.com` → pakai cert yang **sama**
> - Cukup 1 set file `.pem` + `.key` untuk semua subdomain

### 3. Server Requirements

- Ubuntu 22.04 atau 24.04 (fresh install recommended)
- Minimal 2 GB RAM (4 GB recommended)
- Root access atau user dengan sudo

## Cara Penggunaan

### Quick Start

```bash
# 1. Clone atau download folder ini

# 2. Pastikan file SSL sudah ada di folder ssl/
ls ssl/
# cloudflare_origin.key  cloudflare_origin.pem

# 3. Jalankan deploy
./deploy.sh
```

### Langkah-langkah Deploy

Script akan memandu Anda secara interaktif:

```
━━━ 1. Server Connection ━━━

  Server IP / Hostname : 103.xx.xx.xx
  SSH User [root]      : root
  SSH Port [22]        : 22
  SSH Private Key Path : ~/.ssh/id_rsa

━━━ 2. Odoo Configuration ━━━

  Odoo Version (17 18 19) [19] : 18
  Domain Name                  : erp.xerpium.com
  Odoo HTTP Port [8069]        : 8069
  Websocket/Longpolling [8072] : 8072
  Install Enterprise? [n]      : n
  Workers (0=dev) [0]          : 0

━━━ 3. Cloudflare DNS & SSL Certificates ━━━

  Root Domain (for SSL folder) [xerpium.com] : xerpium.com
  ✓ SSL certificate : ssl/cloudflare_origin.pem
  ✓ SSL private key : ssl/cloudflare_origin.key

  Cloudflare API Token (kosongkan jika skip setting DNS) : <paste_api_token_disini>
  ⟳ Configuring Cloudflare DNS for erp.xerpium.com...
  ✓ Cloudflare DNS Configured: CNAME created

━━━ 4. PgBouncer Configuration ━━━

  PgBouncer Port [6432]           : 6432
  Pool Mode (transaction) [transaction] : transaction

━━━ 5. Additional Options ━━━

  Generate Random Admin Password? [y] : y
  Install wkhtmltopdf? [y]            : y

  Proceed with deployment? (y/n) : y
```

Script kemudian akan:
1. Update DNS di Cloudflare jika API token diberikan (idempotent, otomatis mendeteksi A/CNAME yang tepat)
2. Upload `odoo_install.sh` ke server
3. Upload SSL certificate ke `/etc/ssl/cloudflare/<root_domain>/`
4. SSH dan jalankan instalasi (output ditampilkan real-time)
5. Verifikasi semua service berjalan

## Setelah Deploy

### Akses Odoo

- **Via HTTPS**: `https://erp.xerpium.com` (melalui Nginx + SSL)
- **Direct**: `http://IP_SERVER:8069` (bypass Nginx)

### Service Management

```bash
# SSH ke server
ssh -i ~/.ssh/your_key.pem root@IP_SERVER

# Odoo
sudo systemctl start odoo-server
sudo systemctl stop odoo-server
sudo systemctl restart odoo-server
sudo systemctl status odoo-server

# PgBouncer
sudo systemctl restart pgbouncer

# Nginx
sudo systemctl restart nginx

# PostgreSQL
sudo systemctl restart postgresql
```

### View Logs

```bash
# Odoo
tail -f /var/log/odoo/odoo-server.log

# Nginx
tail -f /var/log/nginx/odoo-access.log
tail -f /var/log/nginx/odoo-error.log

# PgBouncer
tail -f /var/log/pgbouncer/pgbouncer.log
```

### File Locations

| Item | Path |
|---|---|
| Odoo config | `/etc/odoo-server.conf` |
| Odoo source | `/odoo/odoo-server/` |
| Custom addons | `/odoo/custom/addons/` |
| Python venv | `/odoo/venv/` |
| SSL certificate | `/etc/ssl/cloudflare/<domain>/cloudflare_origin.pem` |
| SSL key | `/etc/ssl/cloudflare/<domain>/cloudflare_origin.key` |
| Nginx vhost | `/etc/nginx/sites-available/<domain>` |
| PgBouncer config | `/etc/pgbouncer/pgbouncer.ini` |

## Deploy Ulang / Server Baru

Untuk deploy ke server baru, cukup jalankan `./deploy.sh` lagi dan masukkan IP server baru. SSL files yang sama akan digunakan otomatis.

## Menambah Custom Addons

```bash
# SSH ke server
ssh -i ~/.ssh/your_key.pem root@IP_SERVER

# Copy addon ke custom folder
cp -r /path/to/your_addon /odoo/custom/addons/

# Set ownership
chown -R odoo:odoo /odoo/custom/addons/your_addon

# Restart Odoo
sudo systemctl restart odoo-server
```

## Troubleshooting

### PgBouncer gagal start

```bash
# Cek log
journalctl -u pgbouncer -n 20

# Biasanya masalah permission
sudo chown postgres:postgres /var/log/pgbouncer
sudo chown postgres:postgres /var/run/pgbouncer
sudo systemctl restart pgbouncer
```

### Odoo tidak bisa connect ke database

```bash
# Test koneksi via PgBouncer
PGPASSWORD=<password> psql -h 127.0.0.1 -p 6432 -U odoo -d postgres -c 'SELECT 1;'

# Cek password di config
grep db_password /etc/odoo-server.conf
```

### Nginx 502 Bad Gateway

```bash
# Cek apakah Odoo running
systemctl status odoo-server

# Cek port
ss -tlnp | grep 8069

# Restart
sudo systemctl restart odoo-server
sudo systemctl restart nginx
```

### SSL error di browser

- Pastikan **Cloudflare SSL mode** diset ke **Full (Strict)**
- Pastikan DNS A record mengarah ke IP server
- Pastikan **proxy (orange cloud)** aktif di Cloudflare DNS

## Arsitektur

```
Client → Cloudflare (CDN + SSL) → Nginx (443/80) → Odoo (8069)
                                                  → PgBouncer (6432) → PostgreSQL (5432)
```

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│  Cloudflare │────▶│    Nginx     │────▶│    Odoo     │
│  (CDN/SSL)  │     │  (port 443)  │     │ (port 8069) │
└─────────────┘     └──────────────┘     └──────┬──────┘
                                                │
                                         ┌──────▼──────┐
                                         │  PgBouncer  │
                                         │ (port 6432) │
                                         └──────┬──────┘
                                                │
                                         ┌──────▼──────┐
                                         │ PostgreSQL  │
                                         │ (port 5432) │
                                         └─────────────┘
```
