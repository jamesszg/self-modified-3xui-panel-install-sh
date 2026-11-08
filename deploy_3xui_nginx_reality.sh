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
set -Eeuo pipefail
umask 077
LOG=/root/deploy.log
exec > >(tee -a "$LOG") 2>&1
chmod 600 "$LOG" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PL='\033[0m'
info(){ echo -e "${GREEN}[INFO]${PL} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${PL} $*"; }
err(){ echo -e "${RED}[ERR]${PL} $*" >&2; }
ask(){ # ask VAR "提示" "默认值"
  local _v=""; read -rp "$2 [${3:-}]: " _v; _v="${_v:-$3}"; printf -v "$1" '%s' "$_v";
}
ask_secret(){ # ask_secret VAR "提示" (不回显, 不进日志)
  local _v=""; read -rsp "$2: " _v; echo; printf -v "$1" '%s' "$_v";
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
# 架构映射 (后面测速下载用, 不再写死 amd64)
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7*|armv6*|armv5*) ARCH="$(uname -m | sed 's/armv/armv/')" ;;
  *) ARCH="" ;;
esac
info "speedtest-go 架构: ${ARCH:-不支持}"

# ---------- 1. 输入与域名-IP匹配 ----------
echo "========== 输入配置 =========="
ask DOMAIN "域名 (如 example.com)" ""
while [[ -z "$DOMAIN" ]]; do warn "域名不能为空"; ask DOMAIN "域名 (如 example.com)" ""; done
PUB_IP=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || echo "")
info "本机公网 IP: ${PUB_IP:-未知}"
DOMAIN_IP=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)
[[ -z "$DOMAIN_IP" ]] && DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | head -1 || true)
[[ -z "$DOMAIN_IP" ]] && DOMAIN_IP=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1 || true)
echo "域名 $DOMAIN 解析到: ${DOMAIN_IP:-未解析}"
if [[ -n "$PUB_IP" && -n "$DOMAIN_IP" && "$PUB_IP" != "$DOMAIN_IP" ]]; then
  warn "域名 IP 与本机 IP 不一致, 证书申请可能失败"
  ask CONTINUE "仍要继续? (y/N)" "N"; [[ "$CONTINUE" == y* ]] || exit 1
elif [[ -z "$DOMAIN_IP" ]]; then
  warn "域名未解析到 A 记录, 请先在 DNS 里添加 A 记录指向 $PUB_IP"
  ask CONTINUE "已添加, 继续? (y/N)" "N"; [[ "$CONTINUE" == y* ]] || exit 1
else info "域名-IP 匹配 OK"; fi

ask PANEL_USER "面板用户名" "admin"
ask_secret PANEL_PASS "面板密码 (回车自动生成, 不回显)"
[[ -z "$PANEL_PASS" ]] && PANEL_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
PANEL_BASE="3xui-$(openssl rand -hex 4)"
ask PANEL_BASE "面板后缀 webBasePath (不带斜杠)" "$PANEL_BASE"
ask DO_REALITY "是否创建 REALITY 443 入站? (y/N)" "y"
ask DO_PANEL_CERT "是否给面板配证书(之后新 TLS 入站可点'从面板配置')? (y/N)" "N"
ask DO_SPEEDTEST "是否部署 LibreSpeed 测速到 / ? (y/N)" "y"
DO_REALIP="N"
if [[ "$DO_REALITY" == y* ]]; then
  ask DO_REALIP "是否启用真实IP(REALITY xver=1+Nginx PROXY protocol, 实验性)? (y/N)" "N"
fi
# 架构不支持测速时自动降级, 避免 Nginx 反代死后端导致 502
if [[ "$DO_SPEEDTEST" == y* && -z "$ARCH" ]]; then warn "当前架构无 speedtest-go 预编译包, 自动跳过测速"; DO_SPEEDTEST="N"; fi
echo "确认: 域名=$DOMAIN  面板=/$PANEL_BASE/  REALITY=$DO_REALITY  真实IP=$DO_REALIP  面板证书=$DO_PANEL_CERT  测速=$DO_SPEEDTEST"
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
  sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings WHERE key='$_key'; INSERT INTO settings (key,value) VALUES ('$_key','$_val');"
  echo "  sql_set $_key = $_val"
}
sql_get(){
  sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='$1' LIMIT 1;" || true
}

# ---------- 2. 基础软件 ----------
info "安装 nginx/certbot/curl/sqlite3/python3 ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq nginx certbot curl wget git sqlite3 python3 ca-certificates openssl binutils >/dev/null 2>&1
nginx -v; certbot --version; python3 --version

# ---------- 3. 测速后端 (LibreSpeed speedtest-go) ----------
if [[ "$DO_SPEEDTEST" == y* && ! -x /opt/speedtest-go/speedtest-backend ]]; then
  info "下载 speedtest-go (arch=$ARCH) ..."
  mkdir -p /opt/speedtest-go; cd /tmp
  curl -fsSL -o stg.tar.gz "https://github.com/librespeed/speedtest-go/releases/download/v1.1.6/speedtest-go_1.1.6_linux_${ARCH}.tar.gz"
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
mkdir -p /var/www/certbot /etc/nginx/snippets
touch /etc/nginx/snippets/sub-proxy.conf; chmod 644 /etc/nginx/snippets/sub-proxy.conf
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

# ---------- 5. Nginx TLS 入口 ----------
# DO_REALITY=y: 只听 127.0.0.1:8443 (443 让给 REALITY 回落)
# DO_REALITY=n: 直接听 443 + 8443 (否则网站/面板无公网入口)
# DO_REALIP=y(且REALITY): 8443 启用 PROXY protocol 接收 REALITY 传来的真实IP
NGINX_TLS_LISTEN="    listen 127.0.0.1:8443 ssl http2;"
NGINX_REALIP=""
if [[ "$DO_REALITY" == y* ]]; then
  if [[ "$DO_REALIP" == y* ]]; then
    NGINX_TLS_LISTEN="    listen 127.0.0.1:8443 ssl http2 proxy_protocol;"
    NGINX_REALIP="    real_ip_header proxy_protocol;
    real_ip_recursive on;"
  fi
else
  NGINX_TLS_LISTEN="    listen 443 ssl http2;
    listen 127.0.0.1:8443 ssl http2;"
fi

# location / : 测速开才反代, 关则返回静态占位页 (避免 502)
NGINX_ROOT_LOCATION=""
if [[ "$DO_SPEEDTEST" == y* ]]; then
  NGINX_ROOT_LOCATION="    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
    }"
else
  NGINX_ROOT_LOCATION="    location / {
        default_type text/html;
        return 200 '<html><body><h1>OK</h1></body></html>';
    }"
fi

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/certbot;
    location /.well-known/acme-challenge/ {}
    location / { return 301 https://\$host\$request_uri; }
}
server {
$NGINX_TLS_LISTEN
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
$NGINX_REALIP
$NGINX_ROOT_LOCATION
    location /$PANEL_BASE/ {
        proxy_pass http://127.0.0.1:2053;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    include /etc/nginx/snippets/sub-proxy.conf;
}
EOF
nginx -t && systemctl reload nginx
# DO_REALIP 时本机直连 8443 会因缺 PROXY 头失败, 只在未启用时测直连
if [[ "$DO_REALIP" != y* ]]; then
  curl -k -fsS https://127.0.0.1:8443/ >/dev/null && info "Nginx TLS 入口 OK" || warn "Nginx TLS 入口本地检测未通过"
else
  info "已启用 PROXY protocol, 跳过 8443 直连检测 (请经 443 验证)"
fi

# ---------- 6. 3x-ui (幂等: 已装则复用, 不覆盖凭据) ----------
XUI_EXISTED="N"
if [[ -x /usr/local/x-ui/x-ui ]]; then
  XUI_EXISTED="Y"
  info "检测到 3x-ui 已安装, 跳过安装器, 复用现有面板/凭据 (本次输入的面板密码不会覆盖现有)"
  if [[ -f /etc/x-ui/install-result.env ]]; then
    # shell 风格 %q 转义文件, 只取 token(字母数字), 密码以已有为准不回写汇总
    TOKEN=$(grep XUI_API_TOKEN /etc/x-ui/install-result.env | cut -d= -f2- | tr -d "\"' \r\t" || echo "")
  fi
  EXIST_BASE=$(sql_get webBasePath | sed 's|^/||; s|/$||' || true)
  [[ -n "${EXIST_BASE:-}" ]] && PANEL_BASE="$EXIST_BASE" && info "复用现有面板后缀: /$PANEL_BASE/"
else
  info "安装 3x-ui ..."
  curl -fsSL https://raw.githubusercontent.com/MHSanaei/3X-UI/master/install.sh -o /tmp/install.sh
  XUI_NONINTERACTIVE=1 XUI_PANEL_PORT=2053 XUI_WEB_BASE_PATH="$PANEL_BASE" \
  XUI_USERNAME="$PANEL_USER" XUI_PASSWORD="$PANEL_PASS" XUI_SERVER_IP="$PUB_IP" \
  XUI_DB_TYPE=sqlite XUI_SSL_MODE=none XUI_ENABLE_FAIL2BAN=false bash /tmp/install.sh >/tmp/3xui-install.log 2>&1
  tail -20 /tmp/3xui-install.log || true
fi
# 面板/订阅仅本地监听: 不用 x-ui setting(常不落库), 停服务后直接改 DB
systemctl stop x-ui || true
sleep 1
cp -a /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak-$(date +%F-%H%M%S) 2>/dev/null || true
sql_set webPort "2053"
sql_set webBasePath "/$PANEL_BASE/"
sql_set webListen "127.0.0.1"
sql_set subListen "127.0.0.1"
sql_set subPort "2096"
sql_set subURI "https://$DOMAIN"
CUR_SUBENABLE=$(sql_get subEnable || true)
[[ -z "${CUR_SUBENABLE:-}" ]] && sql_set subEnable "true" || true
# 订阅额外保护: 强制随机前缀(后缀)路径, 不依赖面板默认(可能为空/可猜)
# 结构: https://域名/<随机前缀>/<每客户端随机subId>  双重随机, 猜不到
CUR_SUBPATH=$(sql_get subPath || true)
if [[ -z "${CUR_SUBPATH:-}" || ${#CUR_SUBPATH} -lt 8 ]]; then
  sql_set subPath "/sub-$(openssl rand -hex 8)/"
  sql_set subJsonPath "/json-$(openssl rand -hex 8)/"
  sql_set subClashPath "/clash-$(openssl rand -hex 8)/"
else
  info "复用已有随机订阅前缀: $CUR_SUBPATH"
fi
echo "DB 回读校验:"
sqlite3 /etc/x-ui/x-ui.db "SELECT key,value FROM settings WHERE key IN ('webPort','webBasePath','webListen','subListen','subPort','subURI','subEnable','subPath','subJsonPath','subClashPath');" || true
systemctl start x-ui; sleep 3
ss -tlnp | grep 2053 || true
ss -tlnp | grep 2096 || true
# Token: 优先 install-result, 兜底 CLI 生成; 去掉引号/空白
TOKEN="${TOKEN:-}"
if [[ -z "$TOKEN" && -f /etc/x-ui/install-result.env ]]; then
  TOKEN=$(grep XUI_API_TOKEN /etc/x-ui/install-result.env | cut -d= -f2- | tr -d "\"' \r\t" || echo "")
fi
[[ -z "$TOKEN" ]] && TOKEN=$(/usr/local/x-ui/x-ui setting -getApiToken 2>/dev/null | tail -1 | tr -d "\"' \r\t" || echo "")
[[ -z "$TOKEN" ]] && { err "API Token 为空, 无法继续"; exit 1; }
BASE="http://127.0.0.1:2053/$PANEL_BASE/panel/api"
LIST_RESP=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/inbounds/list" || echo "")
echo "$LIST_RESP" | grep -q '"success":true' || { err "API Token 校验失败: $LIST_RESP"; exit 1; }
info "API Token 校验 OK. 面板: https://$DOMAIN/$PANEL_BASE/"

# 订阅经 Nginx 443 转发: 按数据库里的 subPath/subJsonPath/subClashPath 生成 location
{
  for _k in subPath subJsonPath subClashPath; do
    _p=$(sql_get "$_k" || true)
    if [[ -n "${_p:-}" ]]; then
      printf '    location %s {\n        proxy_pass http://127.0.0.1:2096;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_http_version 1.1;\n    }\n' "$_p"
    fi
  done
} > /etc/nginx/snippets/sub-proxy.conf
chmod 644 /etc/nginx/snippets/sub-proxy.conf
nginx -t && systemctl reload nginx && info "订阅已绑本地并经 Nginx 443 转发 (2096 不再公网暴露)"

# ---------- 7. REALITY 入站 (幂等: 已有 443 则复用) ----------
REALITY_LINK=""
if [[ "$DO_REALITY" == y* ]]; then
  EXISTING=$(python3 - "$LIST_RESP" <<'PY' || true
import json,sys
try:
    d=json.loads(sys.argv[1]); objs=d.get("obj") or []
    for o in objs:
        if o.get("port")==443 and o.get("protocol")=="vless":
            rs=(o.get("streamSettings") or {}).get("realitySettings") or {}
            st=rs.get("settings") or {}
            cl=(o.get("settings") or {}).get("clients") or [{}]
            print(json.dumps({"id":o.get("id"),"uuid":cl[0].get("id",""),"pub":st.get("publicKey",""),"priv":rs.get("privateKey",""),"sid":(rs.get("shortIds") or [""])[0],"subId":cl[0].get("subId","")}))
            break
except Exception:
    pass
PY
)
  if [[ -n "${EXISTING:-}" ]]; then
    info "检测到已有 REALITY 443 入站, 复用 (不重复创建)"
    UUID=$(echo "$EXISTING" | python3 -c 'import json,sys; print(json.load(sys.stdin)["uuid"])')
    PUB=$(echo "$EXISTING" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pub"])')
    PRIV=$(echo "$EXISTING" | python3 -c 'import json,sys; print(json.load(sys.stdin)["priv"])')
    SID=$(echo "$EXISTING" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sid"])')
    SUBID=$(echo "$EXISTING" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("subId",""))')
    INBOUND_ID=$(echo "$EXISTING" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
    # 已有客户端 subId 为空(二维码会报错): 现场补一个随机 subId 并经 API 回写
    if [[ -z "${SUBID:-}" ]]; then
      SUBID=$(openssl rand -hex 8)
      info "已有客户端 subId 为空, 补随机 subId: $SUBID"
      curl -s -H "Authorization: Bearer $TOKEN" "$BASE/inbounds/get/$INBOUND_ID" > /tmp/existing.json
      python3 - "$SUBID" <<'PY'
import json,sys
d=json.load(open("/tmp/existing.json")); o=d["obj"]
o["settings"]["clients"][0]["subId"]=sys.argv[1]
json.dump(o,open("/tmp/existing_update.json","w"))
PY
      chmod 600 /tmp/existing_update.json
      RESP2=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "$BASE/inbounds/update/$INBOUND_ID" -d @/tmp/existing_update.json || echo "")
      rm -f /tmp/existing.json /tmp/existing_update.json
      echo "$RESP2" | grep -q '"success":true' && systemctl restart x-ui && sleep 3 || warn "subId 回写失败, 请在面板手动补 subId"
    fi
  else
    KEYS=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
    PRIV=$(echo "$KEYS" | grep PrivateKey | awk '{print $NF}')
    PUB=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519 -i "$PRIV" | grep PublicKey | awk '{print $NF}')
    UUID=$(cat /proc/sys/kernel/random/uuid); SID=$(openssl rand -hex 4)
    SUBID=$(openssl rand -hex 8)
    XVER=0; [[ "$DO_REALIP" == y* ]] && XVER=1
    python3 - "$PRIV" "$PUB" "$UUID" "$SID" "$DOMAIN" "$XVER" "$SUBID" <<'PY'
import json,sys
priv,pub,uuid,sid,dom,xver,subid=sys.argv[1:8]
obj={"remark":"REALITY-443","enable":True,"listen":"","port":443,"protocol":"vless",
 "settings":{"clients":[{"id":uuid,"flow":"","email":"reality-main","totalGB":0,"expiryTime":0,"enable":True,"tgId":"","subId":subid,"comment":"","reset":0}],"decryption":"none","encryption":"none"},
 "streamSettings":{"network":"tcp","security":"reality","tcpSettings":{"acceptProxyProtocol":False,"header":{"type":"none"}},
  "realitySettings":{"show":False,"xver":int(xver),"target":"127.0.0.1:8443","serverNames":[dom],"privateKey":priv,"minClientVer":"","maxClientVer":"","maxTimediff":0,"shortIds":[sid],"settings":{"publicKey":pub,"fingerprint":"chrome","spiderX":"/","mldsa65Verify":""},"mldsa65Seed":"","masterKeyLog":""}},
 "sniffing":{"enabled":True,"destOverride":["http","tls","quic"],"metadata":{"mode":"unified"}},"tag":"inbound-443","total":0,"expiryTime":0}
json.dump(obj,open("/tmp/inbound.json","w"),indent=2)
PY
    chmod 600 /tmp/inbound.json
    RESP=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "$BASE/inbounds/add" -d @/tmp/inbound.json || echo "")
    rm -f /tmp/inbound.json
    echo "$RESP"
    echo "$RESP" | grep -q '"success":true' || { err "REALITY 入站创建失败 (API 未返回 success)"; exit 1; }
    systemctl restart x-ui; sleep 3
  fi
  REALITY_LINK="vless://$UUID@$PUB_IP:443?security=reality&encryption=none&pbk=$PUB&fp=chrome&sni=$DOMAIN&sid=$SID&type=tcp#REALITY-443"
  SUB_PATH_VAL=$(sql_get subPath || true)
  printf "PRIV=%s\nPUB=%s\nUUID=%s\nSID=%s\nSUBID=%s\nSUB_URL=https://%s%s%s\n" "$PRIV" "$PUB" "$UUID" "$SID" "${SUBID:-}" "$DOMAIN" "${SUB_PATH_VAL:-/sub/}" "${SUBID:-}" > /root/reality_client.txt; chmod 600 /root/reality_client.txt
  info "REALITY: $REALITY_LINK"
  info "订阅(随机前缀+随机subId): https://$DOMAIN${SUB_PATH_VAL:-/sub/}${SUBID:-}"
fi

# ---------- 8. 可选: 面板复用证书 ----------
if [[ "$DO_PANEL_CERT" == y* ]]; then
  info "给面板配证书 (为使新 TLS 入站可用'从面板配置')..."
  systemctl stop x-ui || true
  sleep 1
  cp -a /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak-$(date +%F-%H%M%S) 2>/dev/null || true
  sql_set webCertFile "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  sql_set webKeyFile "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  sql_set webCert "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  sql_set webKey "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  echo "DB 回读校验:"
  sqlite3 /etc/x-ui/x-ui.db "SELECT key,value FROM settings WHERE key LIKE 'web%Cert%' OR key LIKE 'web%Key%';" || true
  systemctl start x-ui; sleep 3
  curl -k -s -o /dev/null -w "面板直连(https): %{http_code}\n" https://127.0.0.1:2053/$PANEL_BASE/ || true
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
ss -tlnp || true
if [[ "$DO_REALIP" != y* ]]; then
  curl -k -s -o /dev/null -w "测速(8443): %{http_code}\n" https://127.0.0.1:8443/ || true
  curl -k -s -o /dev/null -w "面板(8443): %{http_code}\n" https://127.0.0.1:8443/$PANEL_BASE/ || true
fi
# 经 443 回落验证 (REALITY 在场时) 或直连 443 验证 (无 REALITY 时)
curl -k -s -o /dev/null -w "经443: %{http_code}\n" --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || true
echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null | grep -E 'subject=|Verify return' || true
# 已装复用时不写新密码 (避免汇总与实际不一致)
SUMMARY_PASS="$PANEL_PASS"; [[ "$XUI_EXISTED" == "Y" ]] && SUMMARY_PASS="(existing, see install-result.env)"
cat > /root/deploy_summary.txt <<EOF
DOMAIN=$DOMAIN
PUB_IP=$PUB_IP
PANEL_URL=https://$DOMAIN/$PANEL_BASE/
PANEL_USER=$PANEL_USER
PANEL_PASS=$SUMMARY_PASS
PANEL_BASE=$PANEL_BASE
API_TOKEN=$TOKEN
REALITY_LINK=$REALITY_LINK
EOF
chmod 600 /root/deploy_summary.txt
cat /root/deploy_summary.txt
info "完成. 防火墙未启用拦截, 新入站端口可直接使用. 建议重启验证: reboot"
