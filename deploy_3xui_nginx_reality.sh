#!/usr/bin/env bash
# ============================================================
# 通用一键部署脚本 (交互式): Nginx + Let's Encrypt + 3x-ui + REALITY
# 功能: 自动鉴别系统/内核/架构, 域名-IP匹配检查,
#       Nginx(127.0.0.1:8443)+Let's Encrypt+LibreSpeed测速
#       +3x-ui面板(仅本地)+REALITY 443(target=127.0.0.1:8443)
#       +可选: 面板复用证书(从面板配置一键填入站)
# 注意: 本脚本绝不启用 ufw/iptables 防火墙拦截,
#       以保证 3x-ui 面板新增的代理端口不被防火墙控制
# 用法: scp -P <SSH_PORT> deploy_3xui_nginx_reality.sh root@<服务器IP>:/root/
#       ssh -p <SSH_PORT> root@<服务器IP>
#       chmod +x /root/deploy_3xui_nginx_reality.sh
#       bash /root/deploy_3xui_nginx_reality.sh
# 隐私说明: 本脚本不含任何真实域名/IP/密码/token, 运行时全部由用户输入
#           或现场自动生成, 汇总文件写入 /root/deploy_summary.txt (600)
#           切勿把该汇总文件提交到代码仓库
# ============================================================
set -u
LOG=/root/deploy.log
exec > >(tee -a "$LOG") 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PL='\033[0m'
info(){ echo -e "${GREEN}[INFO]${PL} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${PL} $*"; }
err(){ echo -e "${RED}[ERR]${PL} $*" >&2; }
ask(){ # ask VAR "提示" "默认值"
  local _v=""; read -rp "$2 [${3:-}]: " _v; _v="${_v:-$3}"; printf -v "$1" '%s' "$_v";
}

# ---------- 0. 系统鉴别 ----------
[[ $EUID -ne 0 ]] && { err "请用 root 运行"; exit 1; }
echo "========== 系统/内核鉴别 =========="
cat /etc/os-release 2>/dev/null | grep -E 'PRETTY_NAME|VERSION_ID' || true
echo "内核: $(uname -r)  架构: $(uname -m)  主机: $(hostname)"
OS_ID=$(. /etc/os-release 2>/dev/null; echo "$ID")
case "$OS_ID" in debian|ubuntu|armbian) ;; *) warn "未在 Debian/Ubuntu 上测试, 继续请确认 (y/N)"; read -rp ">> " c; [[ "$c" == y* ]] || exit 1;; esac
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -oE ':[0-9]+ ' | head -1 | tr -d ': ' || echo 22)
info "检测到 SSH 端口: ${SSH_PORT:-22} (脚本不会改动 SSH 配置)"

# ---------- 1. 输入与域名-IP匹配 ----------
echo "========== 输入配置 =========="
ask DOMAIN "域名 (如 example.com)" ""
while [[ -z "$DOMAIN" ]]; do warn "域名不能为空"; ask DOMAIN "域名 (如 example.com)" ""; done
PUB_IP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || echo "")
info "本机公网 IP: ${PUB_IP:-未知}"
DOMAIN_IP=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1)
[[ -z "$DOMAIN_IP" ]] && DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
[[ -z "$DOMAIN_IP" ]] && DOMAIN_IP=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)
echo "域名 $DOMAIN 解析到: ${DOMAIN_IP:-未解析}"
if [[ -n "$PUB_IP" && -n "$DOMAIN_IP" && "$PUB_IP" != "$DOMAIN_IP" ]]; then
  warn "域名 IP 与本机 IP 不一致, 证书申请可能失败"
  ask CONTINUE "仍要继续? (y/N)" "N"; [[ "$CONTINUE" == y* ]] || exit 1
elif [[ -z "$DOMAIN_IP" ]]; then
  warn "域名未解析到 A 记录, 请先在 DNS 里添加 A 记录指向 $PUB_IP"
  ask CONTINUE "已添加, 继续? (y/N)" "N"; [[ "$CONTINUE" == y* ]] || exit 1
else info "域名-IP 匹配 OK"; fi

ask PANEL_USER "面板用户名" "admin"
ask PANEL_PASS "面板密码 (回车自动生成)" ""
[[ -z "$PANEL_PASS" ]] && PANEL_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
PANEL_BASE="3xui-$(openssl rand -hex 4)"
ask PANEL_BASE "面板后缀 webBasePath (不带斜杠)" "$PANEL_BASE"
ask DO_REALITY "是否创建 REALITY 443 入站? (y/N)" "y"
ask DO_PANEL_CERT "是否给面板配证书(之后新 TLS 入站可点'从面板配置')? (y/N)" "N"
ask DO_SPEEDTEST "是否部署 LibreSpeed 测速到 / ? (y/N)" "y"
echo "确认: 域名=$DOMAIN  面板=/ $PANEL_BASE/  REALITY=$DO_REALITY  面板证书=$DO_PANEL_CERT"
ask OK "确认开始部署? (y/N)" "N"; [[ "$OK" == y* ]] || exit 1

backup(){
  local t=$(date +%F-%H%M%S); mkdir -p /root/backup-$t
  cp -a /etc/nginx/sites-available/default /etc/nginx/nginx.conf /root/backup-$t/ 2>/dev/null || true
  cp -a /etc/x-ui/x-ui.db /root/backup-$t/ 2>/dev/null || true
  cp -a /etc/letsencrypt /root/backup-$t/letsencrypt 2>/dev/null || true
  echo "/root/backup-$t"
}
BK=$(backup); info "已备份到 $BK"

# 直接改数据库的辅助函数: x-ui setting 命令在新版常不落库,
# 这里停服务后用 sqlite3 UPSERT settings 表, 改完重启生效
sql_set(){
  local _key="$1" _val="$2"
  # 值里不应含单引号(路径/端口/后缀均安全), 先删后插防重复键
  sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings WHERE key='$_key'; INSERT INTO settings (key,value) VALUES ('$_key','$_val');"
  echo "  sql_set $_key = $_val"
}
sql_get(){
  sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='$1' LIMIT 1;"
}

# ---------- 2. 基础软件 ----------
info "安装 nginx/certbot/curl/sqlite3 ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq nginx certbot curl wget git sqlite3 ca-certificates openssl binutils >/dev/null 2>&1
nginx -v; certbot --version

# ---------- 3. 测速后端 (LibreSpeed speedtest-go) ----------
if [[ "$DO_SPEEDTEST" == y* && ! -x /opt/speedtest-go/speedtest-backend ]]; then
  info "下载 speedtest-go ..."
  mkdir -p /opt/speedtest-go; cd /tmp
  curl -fsSL -o stg.tar.gz https://github.com/librespeed/speedtest-go/releases/download/v1.1.6/speedtest-go_1.1.6_linux_amd64.tar.gz
  tar -xzf stg.tar.gz -C /opt/speedtest-go
  cat > /opt/speedtest-go/settings.toml <<'EOF'
bind_address="127.0.0.1"
listen_port=3000
proxyprotocol_port=0
server_lat=0
server_lng=0
ipinfo_api_key=""
assets_path=""
statistics_password=""
redact_ip_addresses=false
database_type="none"
database_hostname=""
database_name=""
database_username=""
database_password=""
database_port=""
database_file="speedtest.db"
enable_tls=false
enable_http2=false
EOF
  cat > /etc/systemd/system/speedtest-go.service <<'EOF'
[Unit]
Description=LibreSpeed speedtest-go
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/speedtest-go
ExecStart=/opt/speedtest-go/speedtest-backend -c /opt/speedtest-go/settings.toml
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now speedtest-go
fi

# ---------- 4. Nginx 80 + 证书 ----------
mkdir -p /var/www/certbot
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/certbot;
    location /.well-known/acme-challenge/ {}
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl reload nginx

if [[ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]]; then
  info "申请 Let's Encrypt 证书 ..."
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --email root@$DOMAIN --agree-tos -n --non-interactive
fi

# ---------- 5. Nginx 127.0.0.1:8443 ----------
# 注意: 若 DO_PANEL_CERT=y, 面板是 HTTPS, 这里先按 HTTP 写, 第8步再改成 https 转发
PANEL_PROXY_SCHEME="http"
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/certbot;
    location /.well-known/acme-challenge/ {}
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location /$PANEL_BASE/ {
        proxy_pass http://127.0.0.1:2053;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
nginx -t && systemctl reload nginx && curl -k -fsS https://127.0.0.1:8443/ >/dev/null && info "Nginx 8443 + 测速 OK"

# ---------- 6. 3x-ui ----------
if [[ ! -x /usr/local/x-ui/x-ui ]]; then
  info "安装 3x-ui ..."
  curl -fsSL https://raw.githubusercontent.com/MHSanaei/3X-UI/master/install.sh -o /tmp/install.sh
  XUI_NONINTERACTIVE=1 XUI_PANEL_PORT=2053 XUI_WEB_BASE_PATH="$PANEL_BASE" \
  XUI_USERNAME="$PANEL_USER" XUI_PASSWORD="$PANEL_PASS" XUI_SERVER_IP="$PUB_IP" \
  XUI_DB_TYPE=sqlite XUI_SSL_MODE=none XUI_ENABLE_FAIL2BAN=false bash /tmp/install.sh >/tmp/3xui-install.log 2>&1
  tail -20 /tmp/3xui-install.log
fi
# 面板仅本地监听: 不用 x-ui setting(常不落库), 停服务后直接改 DB
# (安装阶段的用户名/密码/端口已由 install.sh 在建库时写入, 这里再用 SQL 强制对齐端口/后缀/监听)
systemctl stop x-ui || true
sleep 1
cp -a /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak-$(date +%F-%H%M%S) 2>/dev/null || true
sql_set webPort "2053"
sql_set webBasePath "/$PANEL_BASE/"
sql_set webListen "127.0.0.1"
echo "DB 回读校验:"
sqlite3 /etc/x-ui/x-ui.db "SELECT key,value FROM settings WHERE key IN ('webPort','webBasePath','webListen');"
systemctl start x-ui; sleep 3
ss -tlnp | grep 2053
TOKEN=$(grep XUI_API_TOKEN /etc/x-ui/install-result.env 2>/dev/null | cut -d= -f2 || echo "")
[[ -z "$TOKEN" ]] && TOKEN=$(/usr/local/x-ui/x-ui setting -getApiToken 2>/dev/null | tail -1 || echo "")
BASE="http://127.0.0.1:2053/$PANEL_BASE/panel/api"
info "面板: https://$DOMAIN/$PANEL_BASE/  用户:$PANEL_USER"

# ---------- 7. REALITY 入站 ----------
REALITY_LINK=""
if [[ "$DO_REALITY" == y* ]]; then
  KEYS=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
  PRIV=$(echo "$KEYS" | grep PrivateKey | awk '{print $NF}')
  PUB=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519 -i "$PRIV" | grep PublicKey | awk '{print $NF}')
  UUID=$(cat /proc/sys/kernel/random/uuid); SID=$(openssl rand -hex 4)
  python3 - "$PRIV" "$PUB" "$UUID" "$SID" "$DOMAIN" <<'PY'
import json,sys
priv,pub,uuid,sid,dom=sys.argv[1:6]
obj={"remark":"REALITY-443","enable":True,"listen":"","port":443,"protocol":"vless",
 "settings":{"clients":[{"id":uuid,"flow":"","email":"reality-main","totalGB":0,"expiryTime":0,"enable":True,"tgId":"","subId":"","comment":"","reset":0}],"decryption":"none","encryption":"none"},
 "streamSettings":{"network":"tcp","security":"reality","tcpSettings":{"acceptProxyProtocol":False,"header":{"type":"none"}},
  "realitySettings":{"show":False,"xver":0,"target":"127.0.0.1:8443","serverNames":[dom],"privateKey":priv,"minClientVer":"","maxClientVer":"","maxTimediff":0,"shortIds":[sid],"settings":{"publicKey":pub,"fingerprint":"chrome","spiderX":"/","mldsa65Verify":""},"mldsa65Seed":"","masterKeyLog":""}},
 "sniffing":{"enabled":True,"destOverride":["http","tls","quic"],"metadata":{"mode":"unified"}},"tag":"inbound-443","total":0,"expiryTime":0}
json.dump(obj,open("/tmp/inbound.json","w"),indent=2)
PY
  curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "$BASE/inbounds/add" -d @/tmp/inbound.json; echo
  systemctl restart x-ui; sleep 3
  REALITY_LINK="vless://$UUID@$PUB_IP:443?security=reality&encryption=none&pbk=$PUB&fp=chrome&sni=$DOMAIN&sid=$SID&type=tcp#REALITY-443"
  printf "PRIV=%s\nPUB=%s\nUUID=%s\nSID=%s\n" "$PRIV" "$PUB" "$UUID" "$SID" > /root/reality_client.txt; chmod 600 /root/reality_client.txt
  info "REALITY 已创建: $REALITY_LINK"
fi

# ---------- 8. 可选: 面板复用证书 ----------
if [[ "$DO_PANEL_CERT" == y* ]]; then
  info "给面板配证书 (为使新 TLS 入站可用'从面板配置')..."
  # 同样不用 setting 命令: 停服务 -> SQL 直接写证书路径 -> 重启
  # 键名在不同版本有 webCertFile/webCert 两种, 两种都写, 面板读到哪个都行
  systemctl stop x-ui || true
  sleep 1
  cp -a /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak-$(date +%F-%H%M%S) 2>/dev/null || true
  sql_set webCertFile "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  sql_set webKeyFile "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  sql_set webCert "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  sql_set webKey "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  echo "DB 回读校验:"
  sqlite3 /etc/x-ui/x-ui.db "SELECT key,value FROM settings WHERE key LIKE 'web%Cert%' OR key LIKE 'web%Key%';"
  systemctl start x-ui; sleep 3
  curl -k -s -o /dev/null -w "面板直连(https): %{http_code}\n" https://127.0.0.1:2053/$PANEL_BASE/ || true
  # Nginx 改为 https 转发到面板
  sed -i "s|proxy_pass http://127.0.0.1:2053;|proxy_pass https://127.0.0.1:2053;\n        proxy_ssl_verify off;\n        proxy_ssl_server_name on;|" /etc/nginx/sites-available/default
  nginx -t && systemctl reload nginx
fi

# ---------- 9. 续期 hook ----------
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
if [[ "$DO_PANEL_CERT" == y* ]]; then
  printf '#!/bin/sh\nsystemctl reload nginx\nsystemctl restart x-ui\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
else
  printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
fi
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ---------- 10. 验证 & 汇总 ----------
echo "========== 验证 =========="
systemctl is-active nginx x-ui speedtest-go || true
ss -tlnp
curl -k -s -o /dev/null -w "测速(8443): %{http_code}\n" https://127.0.0.1:8443/
curl -k -s -o /dev/null -w "面板(8443): %{http_code}\n" https://127.0.0.1:8443/$PANEL_BASE/
echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null | grep -E 'subject=|Verify return'
cat > /root/deploy_summary.txt <<EOF
DOMAIN=$DOMAIN
PUB_IP=$PUB_IP
PANEL_URL=https://$DOMAIN/$PANEL_BASE/
PANEL_USER=$PANEL_USER
PANEL_PASS=$PANEL_PASS
PANEL_BASE=$PANEL_BASE
API_TOKEN=$TOKEN
REALITY_LINK=$REALITY_LINK
EOF
chmod 600 /root/deploy_summary.txt
cat /root/deploy_summary.txt
info "完成. 防火墙未启用拦截, 新入站端口可直接使用. 建议重启验证: reboot"
