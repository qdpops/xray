#!/bin/bash
set -e

# ═══════════════════════════════════════════════════════════════
#  XRAY + NGINX DEPLOY SCRIPT
#  Транспорт: XHTTP (SplitHTTP)  |  Протокол: VLESS
# ═══════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Проверка root ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Запусти скрипт от root: sudo bash $0"

# ── Параметры ───────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       XRAY + NGINX DEPLOY SCRIPT        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

read -rp "Домен (например: vpn.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && error "Домен не может быть пустым"

read -rp "Email для Let's Encrypt: " EMAIL
[[ -z "$EMAIL" ]] && error "Email не может быть пустым"

read -rp "Path для XRAY (Enter = случайный): " XRAY_PATH
if [[ -z "$XRAY_PATH" ]]; then
    XRAY_PATH="/$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 8)"
fi
# Убедимся что начинается с /
[[ "${XRAY_PATH:0:1}" != "/" ]] && XRAY_PATH="/$XRAY_PATH"

UUID=$(cat /proc/sys/kernel/random/uuid)
SOCK_PATH="/dev/shm/xray-xhttp.sock"
WEB_ROOT="/var/www/${DOMAIN}"

echo ""
info "Домен:    $DOMAIN"
info "Path:     $XRAY_PATH"
info "UUID:     $UUID"
echo ""
read -rp "Всё верно? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && error "Отменено"

# ── Зависимости ─────────────────────────────────────────────────
info "Устанавливаю зависимости..."
apt-get update -qq
apt-get install -y -qq curl wget nginx certbot python3-certbot-nginx unzip uuid-runtime
success "Зависимости установлены"

# ── Xray ────────────────────────────────────────────────────────
info "Устанавливаю Xray..."
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
success "Xray установлен: $(xray version | head -1)"

# ── Certbot (HTTP challenge через nginx) ────────────────────────
info "Получаю SSL-сертификат для $DOMAIN..."

# Временный nginx для верификации
mkdir -p "$WEB_ROOT"
cat > /etc/nginx/sites-available/certbot-temp.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
ln -sf /etc/nginx/sites-available/certbot-temp.conf /etc/nginx/sites-enabled/certbot-temp.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

certbot certonly \
    --nginx \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    -d "$DOMAIN" || error "Не удалось получить сертификат. Убедись что DNS домена смотрит на этот сервер."

rm -f /etc/nginx/sites-enabled/certbot-temp.conf /etc/nginx/sites-available/certbot-temp.conf
success "Сертификат получен"

# ── Заглушка HTML ───────────────────────────────────────────────
info "Создаю страницу-заглушку..."
mkdir -p "$WEB_ROOT"
cat > "$WEB_ROOT/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #0f0f0f;
            color: #e0e0e0;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
        }
        .container { text-align: center; padding: 2rem; }
        h1 { font-size: 2rem; font-weight: 300; color: #fff; margin-bottom: 0.5rem; }
        p  { font-size: 0.95rem; color: #666; }
        .dot {
            width: 8px; height: 8px;
            background: #22c55e;
            border-radius: 50%;
            display: inline-block;
            margin-right: 6px;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50%       { opacity: 0.3; }
        }
    </style>
</head>
<body>
    <div class="container">
        <h1><span class="dot"></span>Service Online</h1>
        <p>Everything is working fine.</p>
    </div>
</body>
</html>
HTMLEOF
success "Заглушка создана"

# ── Nginx конфиг ─────────────────────────────────────────────────
info "Настраиваю Nginx..."
cat > /etc/nginx/sites-available/${DOMAIN}.conf <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP → HTTPS
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

# HTTPS
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # ── XRAY XHTTP ──────────────────────────────────────────────
    location ${XRAY_PATH} {
        proxy_pass          http://unix:${SOCK_PATH};
        proxy_http_version  1.1;
        proxy_set_header    Host              \$host;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;

        proxy_redirect          off;
        proxy_buffering         off;
        proxy_cache             off;
        proxy_request_buffering off;
        proxy_socket_keepalive  on;

        proxy_read_timeout  300s;
        proxy_send_timeout  300s;
    }

    # ── Заглушка ─────────────────────────────────────────────────
    location / {
        root  $WEB_ROOT;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/${DOMAIN}.conf /etc/nginx/sites-enabled/${DOMAIN}.conf
nginx -t || error "Ошибка в конфиге nginx"
systemctl reload nginx
success "Nginx настроен"

# ── Xray конфиг ──────────────────────────────────────────────────
info "Настраиваю Xray..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "xhttp-in",
      "listen": "${SOCK_PATH}",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${XRAY_PATH}",
          "mode": "auto",
          "noGRPCHeader": true,
          "xmux": {
            "maxConcurrency": 16,
            "maxConnections": 0,
            "cMaxReuseTimes": 128,
            "hMaxRequestTimes": "200-400",
            "hKeepAlivePeriod": 0
          }
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "direct",  "protocol": "freedom" },
    { "tag": "blocked", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

# ── Systemd хук для прав на сокет ───────────────────────────────
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/socket-perms.conf <<EOF
[Service]
ExecStartPost=/bin/bash -c 'sleep 1 && chmod 666 ${SOCK_PATH}'
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2

# ── Проверка сокета ──────────────────────────────────────────────
if [[ -S "$SOCK_PATH" ]]; then
    chmod 666 "$SOCK_PATH"
    success "Xray запущен, сокет создан"
else
    warn "Сокет не найден, проверь: journalctl -u xray -n 20"
fi

# ── Финальная проверка ───────────────────────────────────────────
info "Проверяю связку nginx → xray..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://${DOMAIN}${XRAY_PATH}" \
    -H "Content-Type: application/octet-stream" \
    --max-time 5 2>/dev/null || true)

if [[ "$HTTP_CODE" == "000" ]] || [[ "$HTTP_CODE" == "" ]]; then
    warn "Нет ответа от сервера (возможно xray держит соединение — это нормально)"
elif [[ "$HTTP_CODE" == "502" ]]; then
    warn "502 Bad Gateway — сокет не поднялся, проверь: journalctl -u xray -n 30"
else
    success "Сервер отвечает (HTTP $HTTP_CODE)"
fi

# ── Генерация ссылки ─────────────────────────────────────────────
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${XRAY_PATH}'))")
VLESS_LINK="vless://${UUID}@${DOMAIN}:443?type=xhttp&security=tls&sni=${DOMAIN}&fp=chrome&path=${ENCODED_PATH}&host=${DOMAIN}&mode=auto#${DOMAIN}"

# ── Итог ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    ГОТОВО!                              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Домен:${NC}    $DOMAIN"
echo -e "${CYAN}UUID:${NC}     $UUID"
echo -e "${CYAN}Path:${NC}     $XRAY_PATH"
echo -e "${CYAN}Сокет:${NC}    $SOCK_PATH"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  Ссылка для подключения (скопируй в v2rayN / Hiddify):${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}${VLESS_LINK}${NC}"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "Сохранено в: ${CYAN}/root/xray-credentials.txt${NC}"

# Сохраняем в файл
cat > /root/xray-credentials.txt <<EOF
DOMAIN=$DOMAIN
UUID=$UUID
PATH=$XRAY_PATH
LINK=$VLESS_LINK
EOF

echo ""
info "Полезные команды:"
echo "  Статус xray:    systemctl status xray"
echo "  Логи xray:      journalctl -u xray -f"
echo "  Рестарт nginx:  systemctl reload nginx"
echo ""
