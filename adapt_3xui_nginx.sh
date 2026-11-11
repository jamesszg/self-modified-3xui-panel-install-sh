#!/usr/bin/env bash
# =============================================================================
# adapt_3xui_nginx.sh — 3x-ui 配置 -> Nginx 一键适配
#
# 读取 3x-ui 当前配置（只读 SQLite），生成匹配的 Nginx 站点、订阅片段和证书
# 续期 hook，nginx -t 校验通过后原子替换，并按需 reload/restart 相关服务。
#
# 与 deploy_3xui_nginx_reality.sh 的分工：
#   deploy 脚本负责首次安装；本脚本负责之后每次 3x-ui 配置变化后的同步：
#   面板端口/后缀/证书、订阅端口/路径、443 入站（REALITY 回落 / PROXY
#   protocol）、测速后端是否在线，都会重新识别后写进 Nginx。
#
# 只读保证：
#   不修改 /etc/x-ui/x-ui.db，不改 SSH/防火墙/系统服务文件；3x-ui 的设置请
#   继续在面板里改，改完运行本脚本即可。
#
# 用法：
#   bash adapt_3xui_nginx.sh              # 检查 -> 预览 diff -> 确认 -> 应用
#   bash adapt_3xui_nginx.sh --dry-run    # 只预览，不写任何文件
#   bash adapt_3xui_nginx.sh --check      # 只检查（0=已一致，1=需适配）
#   bash adapt_3xui_nginx.sh -y           # 非交互（cron/自动化）
#
# 参数：
#   -n, --dry-run              只生成并打印差异
#       --check                只读检查；不写文件、不重启
#   -y, --yes                  跳过确认
#       --force                覆盖“非本脚本/deploy 脚本生成”的 Nginx 配置
#       --no-reload            写文件且 nginx -t，但不 reload/restart
#       --restart-x-ui=MODE    auto|always|never（默认 auto）
#       --domain=DOMAIN        覆盖域名（默认取面板 webDomain/证书/现有 Nginx）
#       --cert=FILE --key=FILE 使用指定证书（默认取 Let's Encrypt live 目录）
#       --speedtest=MODE       auto|on|off（默认 auto：3000 有监听就反代）
#       --no-backup-db         备份时不复制 x-ui.db
#   -V, --version
#   -h, --help
#
# 环境变量（一般不用改，便于测试/特殊目录）：
#   XUI_DB NGINX_DIR LE_DIR WEBROOT SYNC_STATE SYNC_LOG BACKUP_ROOT LOCK_FILE XUI_BIN
#
# 生成/管理的文件：
#   /etc/nginx/sites-available/default                     主站（80+TLS+面板+根）
#   /etc/nginx/snippets/sub-proxy.conf                     订阅路径反代
#   /etc/letsencrypt/renewal-hooks/deploy/3xui-sync-reload.sh
#   /etc/x-ui/nginx-sync.state                             最近一次适配结果（600）
#   /root/backup-3xui-sync-<时间>/                         每次应用前的备份
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROG=${0##*/}
VERSION='1.0.0'

# ---------- 可覆盖路径 ----------
XUI_DB=${XUI_DB:-/etc/x-ui/x-ui.db}
NGINX_DIR=${NGINX_DIR:-/etc/nginx}
LE_DIR=${LE_DIR:-/etc/letsencrypt}
WEBROOT=${WEBROOT:-/var/www/certbot}
SYNC_STATE=${SYNC_STATE:-/etc/x-ui/nginx-sync.state}
SYNC_LOG=${SYNC_LOG:-/var/log/3xui-nginx-sync.log}
BACKUP_ROOT=${BACKUP_ROOT:-/root}
LOCK_FILE=${LOCK_FILE:-/var/lock/3xui-nginx-sync.lock}
XUI_BIN=${XUI_BIN:-/usr/local/x-ui/x-ui}

MAIN_CONF="$NGINX_DIR/sites-available/default"
SUB_CONF="$NGINX_DIR/snippets/sub-proxy.conf"
HOOK_FILE="$LE_DIR/renewal-hooks/deploy/3xui-sync-reload.sh"
MAIN_MARK='Managed by adapt_3xui_nginx.sh'
SUB_MARK='Managed by adapt_3xui_nginx.sh (3x-ui subscription paths)'
HOOK_MARK='Managed by adapt_3xui_nginx.sh (certbot deploy hook)'

# ---------- 运行参数 ----------
DRY_RUN=0
CHECK_ONLY=0
ASSUME_YES=0
FORCE=0
DO_RELOAD=1
RESTART_XUI='auto'
SPEEDTEST_MODE='auto'
BACKUP_DB=1
OPT_DOMAIN=''
OPT_CERT=''
OPT_KEY=''

# ---------- 运行期状态 ----------
TMP=''
BK=''
LOCK_MKDIR=0
LOCK_DIR=''
ROLLBACK_ARMED=0
LINK=''
LINK_REPLACED=0
LINK_CREATED=0
XUI_INSTALLED=0
XUI_DRIFT=0
XUI_NEEDS_SERVICE=0
XUI_RESTARTED=0
NGINX_RELOADED=0
SPEEDTEST_STARTED=0
TAKEOVER_BLOCKED=0
ENV_WEB_PORT=''

WEB_PORT=2053
WEB_LISTEN=''
WEB_BASE_RAW=''
WEB_DOMAIN=''
WEB_CERT=''
WEB_KEY=''
PANEL_BASE=''
PANEL_PATH='/'
PANEL_LOC='/'
PANEL_HTTPS=0
PANEL_SCHEME='http'
PANEL_HOST='127.0.0.1'

SUB_ENABLED=0
SUB_PORT=2096
SUB_LISTEN=''
SUB_HOST='127.0.0.1'
SUB_SCHEME='http'
SUB_HTTPS=0
SUB_CERT=''
SUB_KEY=''
SUB_PATH_RAW=''
SUB_JSON_PATH_RAW=''
SUB_CLASH_PATH_RAW=''
SUB_JSON_ENABLED=0
SUB_CLASH_ENABLED=0
SUB_URI=''
SUB_LOCS=()
declare -A SUB_SEEN=()
SUB_SUMMARY='未启用'
SUB_PATH_LIST=''
SUB_PROBE_PATHS=''
SUB_PROBE_ID=''
SUB_PATH_DISPLAY=''
SUB_PROBE_URL=''

DOMAIN=''
CERT_FILE=''
CERT_KEY=''
CERT_SOURCE=''
CERT_EXPIRY=''

REALITY_443=0
XVER=0
REALITY_TARGET=''
REALITY_FALLBACK_OK=0
NGINX_OWNS_443=1
PORT_443_SUMMARY=''

SPEEDTEST_ENABLED=0
SPEEDTEST_NEEDS_START=0
SPEEDTEST_SUMMARY=''

NGINX_VER=''
HTTP2_MODERN=0
HTTP2_SUMMARY=''
TLS_LISTEN_BLOCK=''
REALIP_BLOCK=''
ROOT_BLOCK=''
PANEL_SSL_BLOCK=''
PANEL_REDIRECT_BLOCK=''
PANEL_PROBE_URL=''

CHANGED_FILES=()
FP=''

# ---------- 输出 ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; PL=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; PL=''
fi
info(){ printf '%s[INFO]%s %s\n' "$GREEN" "$PL" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$YELLOW" "$PL" "$*"; }
err(){ printf '%s[ERR]%s %s\n' "$RED" "$PL" "$*" >&2; }
die(){ err "$*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  cat <<'EOF'
3x-ui 配置 -> Nginx 一键适配

用法:
  bash adapt_3xui_nginx.sh [选项]

选项:
  -n, --dry-run              只生成并打印差异，不写文件
      --check                只读检查：0=已一致，1=需适配
  -y, --yes                  跳过确认（非交互）
      --force                覆盖非本脚本生成的 Nginx 配置（会先备份）
      --no-reload            写文件并 nginx -t，但不 reload/restart
      --restart-x-ui=MODE    auto|always|never（默认 auto）
      --domain=DOMAIN        覆盖域名
      --cert=FILE            指定证书 fullchain.pem
      --key=FILE             指定证书私钥 privkey.pem
      --speedtest=MODE       auto|on|off（默认 auto）
      --no-backup-db         备份时不复制 x-ui.db
  -V, --version
  -h, --help

说明:
  脚本只读 3x-ui 数据库，生成:
    /etc/nginx/sites-available/default
    /etc/nginx/snippets/sub-proxy.conf
    /etc/letsencrypt/renewal-hooks/deploy/3xui-sync-reload.sh
  应用前备份到 /root/backup-3xui-sync-<时间>/，nginx -t 失败自动回滚。

  面板里改了后缀/订阅路径/证书后，再跑一次本脚本即可。
EOF
}

# =============================================================================
# 基础工具
# =============================================================================
trim(){
  local s=${1-}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

unquote(){
  local s=${1-}
  s=${s%\"}; s=${s#\"}
  s=${s%\'}; s=${s#\'}
  printf '%s' "$s"
}

lower(){
  printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'
}

valid_port(){
  [[ ${1-} =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_host(){
  local h=${1-}
  [[ -z $h ]] && return 0
  [[ $h =~ ^[A-Za-z0-9._:-]+$ ]]
}

valid_path(){
  local p=${1-}
  [[ -z $p ]] && return 0
  [[ $p =~ ^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] || return 1
  [[ /$p/ == */../* || /$p/ == */./* ]] && return 1
  return 0
}

norm_path(){
  local p
  p=$(trim "${1-}")
  p=${p#/}
  p=${p%/}
  printf '%s' "$p"
}

norm_domain(){
  local d
  d=$(trim "${1-}")
  d=${d#http://}; d=${d#https://}
  d=${d%%/*}
  d=${d%%:*}
  d=${d%.}
  lower "$d"
}

valid_domain(){
  [[ ${1-} =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]
}

as_bool(){
  case $(lower "${1-}") in
    true|1|yes|on) printf '1' ;;
    *) printf '0' ;;
  esac
}

local_host(){
  case ${1-} in
    ''|0.0.0.0|'::'|'[::]'|'*') printf '127.0.0.1' ;;
    *) printf '%s' "$1" ;;
  esac
}

is_loopback(){
  case ${1-} in
    127.*|'::1'|'[::1]'|localhost) return 0 ;;
  esac
  return 1
}

nginx_path_ok(){
  case ${1-} in
    ''|*'$'*|*'"'*|*$'\n'*) return 1 ;;
  esac
  return 0
}

ver_ge(){
  [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$2" ]]
}

hash_stdin(){
  if have sha256sum; then
    sha256sum | cut -d' ' -f1
  elif have shasum; then
    shasum -a 256 | cut -d' ' -f1
  else
    cksum | tr ' ' '-'
  fi
}

# =============================================================================
# 进程/服务
# =============================================================================
svc_active(){
  have systemctl || return 1
  systemctl is-active --quiet "$1" 2>/dev/null
}

port_listening(){
  have ss || return 1
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}\$"
}

wait_port(){
  local port=$1 tries=${2:-15} i=0
  have ss || return 0
  while (( i < tries )); do
    port_listening "$port" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

http_code(){
  local url=$1
  shift
  local out
  out=$(curl -k -s -m 8 -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null) || true
  printf '%s' "${out:-000}"
}

tls_curl_code(){
  local path=$1
  if (( REALITY_443 )) && (( XVER == 0 )); then
    http_code "https://127.0.0.1:8443$path"
  else
    http_code "https://$DOMAIN$path" --resolve "$DOMAIN:443:127.0.0.1"
  fi
}

# =============================================================================
# 证书
# =============================================================================
cert_pair_ok(){
  [[ -n ${1-} && -n ${2-} && -f ${1-} && -f ${2-} ]] || return 1
  openssl x509 -in "$1" -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$2" -noout >/dev/null 2>&1 || return 1
  return 0
}

cert_sans(){
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p' | tr -d ' \r' || true
}

cert_cn(){
  local cn
  cn=$(openssl x509 -in "$1" -noout -subject 2>/dev/null \
    | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,]*\).*/\1/p' | head -1 || true)
  trim "$cn"
}

san_match(){
  local d=${1-} s
  [[ -n $d ]] || return 1
  for s in ${2-}; do
    [[ $s == "$d" ]] && return 0
    if [[ $s == '*.'* && ${d#*.} == "${s#*.}" ]]; then return 0; fi
  done
  return 1
}

# =============================================================================
# 日志/锁/临时目录
# =============================================================================
init_log(){
  local dir sz
  dir=$(dirname "$SYNC_LOG")
  mkdir -p "$dir" 2>/dev/null || true
  if ! { : >>"$SYNC_LOG"; } 2>/dev/null; then
    SYNC_LOG="$BACKUP_ROOT/3xui-nginx-sync.log"
    mkdir -p "$(dirname "$SYNC_LOG")" 2>/dev/null || true
    : >>"$SYNC_LOG" 2>/dev/null || SYNC_LOG=/dev/null
  fi
  chmod 600 "$SYNC_LOG" 2>/dev/null || true
  if [[ $SYNC_LOG != /dev/null ]] && have stat; then
    sz=$(stat -c%s "$SYNC_LOG" 2>/dev/null || echo 0)
    if [[ $sz =~ ^[0-9]+$ ]] && (( sz > 5242880 )); then
      mv -f "$SYNC_LOG" "$SYNC_LOG.1" 2>/dev/null || true
    fi
  fi
  exec > >(tee -a "$SYNC_LOG") 2>&1
}

acquire_lock(){
  local dir
  dir=$(dirname "$LOCK_FILE")
  mkdir -p "$dir" 2>/dev/null || true
  if have flock; then
    exec 9>"$LOCK_FILE" || die "无法创建锁文件: $LOCK_FILE"
    flock -n 9 || die "另一个适配进程正在运行（锁: $LOCK_FILE）"
  else
    LOCK_DIR="$LOCK_FILE.d"
    mkdir "$LOCK_DIR" 2>/dev/null || die "另一个适配进程正在运行（目录锁: $LOCK_DIR）；确认无进程后可删除该目录"
    LOCK_MKDIR=1
  fi
}

on_exit(){
  if (( ROLLBACK_ARMED )); then
    err '检测到未完成的应用，正在回滚 Nginx 配置'
    restore_backup
  fi
  if [[ -n $TMP && -d $TMP ]]; then rm -rf "$TMP"; fi
  if (( LOCK_MKDIR )); then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
}

# =============================================================================
# 3x-ui 数据库（只读）
# =============================================================================
sqlite_ro(){
  sqlite3 -readonly -cmd '.timeout 5000' "$XUI_DB" "$1" 2>/dev/null
}

get_setting(){
  local v
  v=$(sqlite_ro "SELECT value FROM settings WHERE key='$1' LIMIT 1;") || v=''
  v=$(unquote "$(trim "$v")")
  printf '%s' "$v"
}

check_env_files(){
  local f ty p folder
  XUI_INSTALLED=0
  [[ -x $XUI_BIN ]] && XUI_INSTALLED=1

  for f in /etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui; do
    [[ -r $f ]] || continue
    ty=$(sed -nE 's/^[[:space:]]*XUI_DB_TYPE=(.*)$/\1/p' "$f" | tail -1 | tr -d "\"'[:space:]" || true)
    case $(lower "$ty") in
      postgres*|pg) die "3x-ui 使用 PostgreSQL（XUI_DB_TYPE=$ty），本脚本只支持 SQLite 数据库" ;;
    esac
    p=$(sed -nE 's/^[[:space:]]*XUI_PORT=(.*)$/\1/p' "$f" | tail -1 | tr -d "\"'[:space:]" || true)
    if valid_port "$p"; then
      ENV_WEB_PORT=$p
      warn "检测到 $f 设置 XUI_PORT=$p，面板实际监听以它为准"
    fi
    folder=$(sed -nE 's/^[[:space:]]*XUI_DB_FOLDER=(.*)$/\1/p' "$f" | tail -1 | tr -d "\"'" || true)
    folder=$(trim "$folder")
    if [[ ! -f $XUI_DB && -n $folder && -f "$folder/x-ui.db" ]]; then
      XUI_DB="$folder/x-ui.db"
      warn "使用 XUI_DB_FOLDER 指向的数据库: $XUI_DB"
    fi
  done
}

check_db(){
  local t
  [[ -f $XUI_DB ]] || die "找不到 3x-ui 数据库: $XUI_DB（用了 Docker/自定义目录时可用 XUI_DB=... 指定）"
  t=$(sqlite_ro "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('settings','inbounds');") || t=0
  [[ $t =~ ^[0-9]+$ ]] || t=0
  (( t >= 2 )) || die "不是有效的 3x-ui SQLite 数据库: $XUI_DB"
}

# =============================================================================
# 读取并规范化 3x-ui 配置
# =============================================================================
load_settings(){
  WEB_PORT=$(get_setting webPort)
  if ! valid_port "$WEB_PORT"; then
    warn "无法读取有效的 webPort，按 2053 处理"
    WEB_PORT=2053
  fi
  if [[ -n $ENV_WEB_PORT ]] && [[ $ENV_WEB_PORT != "$WEB_PORT" ]]; then
    warn "XUI_PORT=$ENV_WEB_PORT 覆盖数据库 webPort=$WEB_PORT，以 XUI_PORT 为准"
    WEB_PORT=$ENV_WEB_PORT
  fi

  WEB_LISTEN=$(get_setting webListen)
  if ! valid_host "$WEB_LISTEN"; then
    warn "webListen 含非法字符，按 127.0.0.1 处理: $WEB_LISTEN"
    WEB_LISTEN='127.0.0.1'
  fi
  if ! is_loopback "$WEB_LISTEN" && [[ -n $WEB_LISTEN ]]; then
    warn "面板监听在 $WEB_LISTEN（非回环），会绕过 Nginx 直接暴露；建议在面板设置里改为 127.0.0.1"
  elif [[ -z $WEB_LISTEN ]]; then
    warn "面板 webListen 为空（等价 0.0.0.0，公网可直接访问 $WEB_PORT），建议在面板设置里改为 127.0.0.1"
  fi
  PANEL_HOST=$(local_host "$WEB_LISTEN")

  WEB_BASE_RAW=$(get_setting webBasePath)
  PANEL_BASE=$(norm_path "$WEB_BASE_RAW")
  valid_path "$PANEL_BASE" || die "webBasePath 含非法字符，无法安全写入 Nginx: $WEB_BASE_RAW"
  if [[ -z $PANEL_BASE ]]; then
    PANEL_PATH='/'
    PANEL_LOC='/'
    warn "面板 webBasePath 为空（面板占用站点根路径 /），测速页将不可用；建议在面板设置里填随机后缀"
  else
    PANEL_PATH="/$PANEL_BASE/"
    PANEL_LOC="/$PANEL_BASE"
  fi

  WEB_DOMAIN=$(get_setting webDomain)
  WEB_CERT=$(get_setting webCertFile)
  WEB_KEY=$(get_setting webKeyFile)
  [[ -z $WEB_CERT ]] && WEB_CERT=$(get_setting webCert)
  [[ -z $WEB_KEY ]] && WEB_KEY=$(get_setting webKey)
  PANEL_HTTPS=0
  if cert_pair_ok "$WEB_CERT" "$WEB_KEY"; then
    PANEL_HTTPS=1
    PANEL_SCHEME=https
  elif [[ -n $WEB_CERT || -n $WEB_KEY ]]; then
    warn "面板证书/私钥不可用或无法解析，面板实际会以 HTTP 运行: cert=$WEB_CERT key=$WEB_KEY"
  fi

  SUB_ENABLED=1
  case $(lower "$(get_setting subEnable)") in
    false|0|no|off) SUB_ENABLED=0 ;;
  esac
  SUB_PORT=$(get_setting subPort)
  if ! valid_port "$SUB_PORT"; then
    warn "无法读取有效的 subPort，按 2096 处理"
    SUB_PORT=2096
  fi
  SUB_LISTEN=$(get_setting subListen)
  if ! valid_host "$SUB_LISTEN"; then
    warn "subListen 含非法字符，按 127.0.0.1 处理: $SUB_LISTEN"
    SUB_LISTEN='127.0.0.1'
  fi
  SUB_HOST=$(local_host "$SUB_LISTEN")
  SUB_CERT=$(get_setting subCertFile)
  SUB_KEY=$(get_setting subKeyFile)
  SUB_HTTPS=0
  if cert_pair_ok "$SUB_CERT" "$SUB_KEY"; then
    SUB_HTTPS=1
    SUB_SCHEME=https
  fi
  if (( SUB_ENABLED )); then
    if ! is_loopback "$SUB_LISTEN" && [[ -n $SUB_LISTEN ]]; then
      warn "订阅服务监听在 $SUB_LISTEN（非回环），会绕过 Nginx 直接暴露；建议改为 127.0.0.1"
    elif [[ -z $SUB_LISTEN ]]; then
      warn "订阅 subListen 为空（等价 0.0.0.0，公网可直接访问 $SUB_PORT），建议改为 127.0.0.1"
    fi
    if [[ $SUB_PORT == "$WEB_PORT" ]] && [[ $SUB_HOST == "$PANEL_HOST" ]]; then
      warn "订阅端口与面板端口相同（$SUB_PORT），3x-ui 无法同时监听，请先改掉一个"
    fi
  fi
  SUB_PATH_RAW=$(get_setting subPath)
  SUB_JSON_PATH_RAW=$(get_setting subJsonPath)
  SUB_CLASH_PATH_RAW=$(get_setting subClashPath)
  SUB_JSON_ENABLED=$(as_bool "$(get_setting subJsonEnable)")
  SUB_CLASH_ENABLED=$(as_bool "$(get_setting subClashEnable)")

  SUB_URI=$(get_setting subURI)
  if (( SUB_ENABLED )) && [[ -z $SUB_URI ]] && [[ $SUB_PORT != 443 ]]; then
    warn "subURI 为空且 subPort=$SUB_PORT，面板生成的订阅地址会带 :$SUB_PORT，客户端可能连不上；建议在面板里把 subURI 设为 https://<域名>"
  fi

  FP=$(printf '%s\n' \
    "$WEB_PORT" "$WEB_LISTEN" "$PANEL_BASE" "$WEB_CERT" "$WEB_KEY" \
    "$SUB_ENABLED" "$SUB_PORT" "$SUB_LISTEN" "$SUB_PATH_RAW" \
    "$SUB_JSON_PATH_RAW" "$SUB_CLASH_PATH_RAW" "$SUB_JSON_ENABLED" \
    "$SUB_CLASH_ENABLED" "$WEB_DOMAIN" | hash_stdin)

  read_sub_probe_id
}

# 取一个真实 subId，用于探测“订阅路径是否已在运行中的 x-ui 里注册”。
# 用 HEAD 请求：3x-ui 只对 GET 记录订阅拉取次数，HEAD 不污染统计。
read_sub_probe_id(){
  SUB_PROBE_ID=''
  (( SUB_ENABLED )) || return 0
  local s
  s=$(sqlite_ro "SELECT replace(settings,' ','') FROM inbounds WHERE enable=1 AND settings LIKE '%subId%' LIMIT 1;") || s=''
  [[ -n $s ]] || return 0
  SUB_PROBE_ID=$(printf '%s' "$s" | grep -oE '"subId":"[A-Za-z0-9_-]+"' | head -1 | cut -d'"' -f4 || true)
  [[ $SUB_PROBE_ID =~ ^[A-Za-z0-9_-]+$ ]] || SUB_PROBE_ID=''
}

# =============================================================================
# 域名与证书
# =============================================================================
detect_domain_and_cert(){
  local webd sn c s base
  DOMAIN=''
  if [[ -n $OPT_DOMAIN ]]; then
    DOMAIN=$(norm_domain "$OPT_DOMAIN")
    valid_domain "$DOMAIN" || die "--domain 不是合法域名: $OPT_DOMAIN"
  fi

  webd=$(norm_domain "$WEB_DOMAIN")
  if [[ -z $DOMAIN && -n $webd ]] && valid_domain "$webd"; then
    DOMAIN=$webd
  fi

  if [[ -z $DOMAIN && -f $MAIN_CONF ]]; then
    sn=$(grep -oE 'server_name[[:space:]]+[^;]+' "$MAIN_CONF" 2>/dev/null | head -1 | awk '{print $2}' || true)
    [[ $sn == '_' ]] && sn=''
    sn=$(norm_domain "$sn")
    if valid_domain "$sn"; then DOMAIN=$sn; fi
  fi

  if [[ -z $DOMAIN ]]; then
    for c in "$LE_DIR"/live/*/cert.pem; do
      [[ -f $c ]] || continue
      s=$(cert_sans "$c" | head -1)
      [[ -z $s ]] && s=$(cert_cn "$c")
      s=${s#\*.}
      if valid_domain "$s"; then DOMAIN=$s; break; fi
    done
  fi

  if [[ -z $DOMAIN ]]; then
    cat >&2 <<EOF
[ERR] 无法确定域名：3x-ui webDomain 为空，证书和现有 Nginx 里也没有可用域名。
  请指定域名后重跑，例如:
    bash $PROG --domain example.com
  或者先在 3x-ui 面板 -> 设置 -> 常规 里填写 webDomain。
EOF
    exit 1
  fi

  if [[ -n $WEB_DOMAIN ]] && ! valid_domain "$(norm_domain "$WEB_DOMAIN")"; then
    warn "3x-ui webDomain 不是合法域名（$WEB_DOMAIN），面板生成的分享链接可能异常"
  elif [[ -z $WEB_DOMAIN ]]; then
    warn "3x-ui webDomain 为空：面板生成的分享链接会写 localhost；建议在面板设置里填 $DOMAIN"
  fi

  if (( SUB_ENABLED )) && [[ -n $SUB_URI ]]; then
    local sub_uri_host
    sub_uri_host=$(printf '%s' "$SUB_URI" | sed -E 's#^[A-Za-z]+://##; s#/.*$##; s#:[0-9]+$##' || true)
    sub_uri_host=$(norm_domain "$sub_uri_host")
    if valid_domain "$sub_uri_host" && [[ $sub_uri_host != "$DOMAIN" ]]; then
      warn "subURI 指向 $sub_uri_host，与域名 $DOMAIN 不一致；订阅链接会写到别的域名"
    fi
  fi

  CERT_FILE=''
  CERT_KEY=''
  CERT_SOURCE=''
  if [[ -n $OPT_CERT || -n $OPT_KEY ]]; then
    [[ -n $OPT_CERT && -n $OPT_KEY ]] || die "--cert 与 --key 必须同时指定"
    cert_pair_ok "$OPT_CERT" "$OPT_KEY" || die "证书或私钥不可用/无法解析: $OPT_CERT / $OPT_KEY"
    CERT_FILE=$OPT_CERT
    CERT_KEY=$OPT_KEY
    CERT_SOURCE='命令行指定'
  elif [[ -f $LE_DIR/live/$DOMAIN/fullchain.pem && -f $LE_DIR/live/$DOMAIN/privkey.pem ]]; then
    CERT_FILE="$LE_DIR/live/$DOMAIN/fullchain.pem"
    CERT_KEY="$LE_DIR/live/$DOMAIN/privkey.pem"
    CERT_SOURCE="Let's Encrypt"
  else
    for c in "$LE_DIR"/live/*/cert.pem; do
      [[ -f $c ]] || continue
      if san_match "$DOMAIN" "$(cert_sans "$c")" || [[ $(cert_cn "$c") == "$DOMAIN" ]]; then
        base=$(dirname "$c")
        [[ -f $base/fullchain.pem && -f $base/privkey.pem ]] || continue
        CERT_FILE="$base/fullchain.pem"
        CERT_KEY="$base/privkey.pem"
        CERT_SOURCE="Let's Encrypt"
        break
      fi
    done
  fi

  if [[ -z $CERT_FILE ]] && cert_pair_ok "$WEB_CERT" "$WEB_KEY"; then
    CERT_FILE=$WEB_CERT
    CERT_KEY=$WEB_KEY
    CERT_SOURCE='3x-ui 面板证书'
    warn "未找到 $DOMAIN 的 Let's Encrypt 证书，改用面板证书: $CERT_FILE"
  fi

  if [[ -z $CERT_FILE ]]; then
    cat >&2 <<EOF
[ERR] 没有找到可用于 $DOMAIN 的证书。
  方案 1（推荐）: 先用 certbot 申请（80 必须可达）:
    certbot certonly --webroot -w $WEBROOT -d $DOMAIN --email root@$DOMAIN --agree-tos -n
  方案 2: 已有证书时显式指定:
    bash $PROG --domain $DOMAIN --cert /path/fullchain.pem --key /path/privkey.pem
EOF
    exit 1
  fi

  if ! { nginx_path_ok "$CERT_FILE" && nginx_path_ok "$CERT_KEY"; }; then
    die "证书路径含 Nginx 配置不支持的字符（\$、引号或换行）: $CERT_FILE"
  fi

  local sans cn
  sans=$(cert_sans "$CERT_FILE")
  cn=$(cert_cn "$CERT_FILE")
  if ! san_match "$DOMAIN" "$sans" && [[ $cn != "$DOMAIN" ]]; then
    warn "证书 SAN/CN 不含 $DOMAIN（SAN: ${sans:-空}），浏览器会报证书错误"
  fi
  if ! openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1; then
    warn "证书已过期: $(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  elif ! openssl x509 -in "$CERT_FILE" -noout -checkend 1209600 >/dev/null 2>&1; then
    warn "证书将在 14 天内到期，请确认自动续期正常"
  fi
  CERT_EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)

  case $CERT_FILE in
    "$LE_DIR"/*) ;;
    *) warn "证书不在 $LE_DIR 下，certbot 续期 hook 不会覆盖它；请在签发工具里配置 reload/restart" ;;
  esac
}

# =============================================================================
# 443 入站检测
# =============================================================================
detect_inbounds(){
  local n stream p proto
  REALITY_443=0
  XVER=0
  REALITY_TARGET=''
  REALITY_FALLBACK_OK=0
  NGINX_OWNS_443=1

  n=$(sqlite_ro "SELECT count(*) FROM inbounds WHERE enable=1 AND port=443;") || n=0
  [[ $n =~ ^[0-9]+$ ]] || n=0
  if (( n > 0 )); then
    NGINX_OWNS_443=0
    stream=$(sqlite_ro "SELECT replace(stream_settings,' ','') FROM inbounds WHERE enable=1 AND port=443 LIMIT 1;") || stream=''
    if [[ $stream == *'"security":"reality"'* ]]; then
      REALITY_443=1
      XVER=$(printf '%s' "$stream" | grep -oE '"xver":[0-9]+' | head -1 | cut -d: -f2 || true)
      REALITY_TARGET=$(printf '%s' "$stream" | grep -oE '"target":"[^"]*"' | head -1 | sed 's/^"target":"//; s/"$//' || true)
      [[ $XVER =~ ^[0-9]+$ ]] || XVER=0
      case $REALITY_TARGET in
        127.0.0.1:8443|localhost:8443) REALITY_FALLBACK_OK=1 ;;
        '') warn "REALITY 443 的 target 为空，普通浏览器不会回落到 Nginx" ;;
        *) warn "REALITY 443 的 target=$REALITY_TARGET，不是 127.0.0.1:8443；网站/面板经 443 不可达（把 target 改成 127.0.0.1:8443 才能回落）" ;;
      esac
      if (( XVER >= 2 )); then
        warn "REALITY xver=$XVER（PROXY protocol v2），请确认 Nginx 版本支持，否则建议在面板改回 1"
      fi
    else
      warn "443 被非 REALITY 入站占用；Nginx 只监听 127.0.0.1:8443，网站/面板可能没有公网入口"
    fi
  fi

  if (( NGINX_OWNS_443 )); then
    PORT_443_SUMMARY='Nginx 直接监听 443'
  elif (( REALITY_443 )); then
    if (( XVER > 0 )); then
      PORT_443_SUMMARY="REALITY 占用 443（xver=$XVER，PROXY protocol 到 127.0.0.1:8443）"
    else
      PORT_443_SUMMARY='REALITY 占用 443 -> 回落 Nginx 127.0.0.1:8443'
    fi
  else
    PORT_443_SUMMARY='443 被入站占用（非 REALITY）-> Nginx 127.0.0.1:8443'
  fi

  while IFS='|' read -r p proto _listen; do
    [[ -n $p ]] || continue
    case $p in
      443) continue ;;
      80)
        die "入站端口 80（$proto）与 Nginx 冲突；请先在面板里改掉这个入站端口"
        ;;
      8443)
        if (( REALITY_443 )); then
          die "入站端口 8443（$proto）与 REALITY 回落用的 Nginx 端口冲突；请改掉这个入站"
        else
          warn "入站占用了 8443（$proto）；本脚本不需要 8443，但该入站不会经 Nginx 回落"
        fi
        ;;
      3000)
        warn "入站端口 3000 与测速后端冲突；若开启测速反代会 502"
        ;;
    esac
    if [[ $p == "$WEB_PORT" ]]; then
      warn "入站端口 $p（$proto）与面板 webPort 相同，二者会冲突"
    fi
    if (( SUB_ENABLED )) && [[ $p == "$SUB_PORT" ]]; then
      warn "入站端口 $p（$proto）与订阅端口相同，二者会冲突"
    fi
  done < <(sqlite_ro "SELECT port, protocol, listen FROM inbounds WHERE enable=1 ORDER BY port;" || true)
}

# =============================================================================
# 测速后端
# =============================================================================
detect_speedtest(){
  local running=0
  if have ss && port_listening 3000; then
    running=1
  elif svc_active speedtest-go; then
    running=1
  fi

  case $SPEEDTEST_MODE in
    on) SPEEDTEST_ENABLED=1 ;;
    off) SPEEDTEST_ENABLED=0 ;;
    auto) SPEEDTEST_ENABLED=$running ;;
  esac

  if (( SPEEDTEST_ENABLED )) && [[ -z $PANEL_BASE ]]; then
    warn "面板占用站点根路径 /，测速反代不可用，已自动关闭"
    SPEEDTEST_ENABLED=0
  fi

  SPEEDTEST_NEEDS_START=0
  if (( SPEEDTEST_ENABLED )); then
    if ! svc_active speedtest-go; then
      if [[ -f /etc/systemd/system/speedtest-go.service ]]; then
        SPEEDTEST_NEEDS_START=1
      else
        warn "未找到 speedtest-go.service，首页会 502；可用 --speedtest=off 关闭"
      fi
    fi
    SPEEDTEST_SUMMARY='反代 127.0.0.1:3000'
  else
    SPEEDTEST_SUMMARY='关闭（根路径返回静态页）'
  fi
  if (( SPEEDTEST_NEEDS_START )); then
    SPEEDTEST_SUMMARY+='（将启动 speedtest-go）'
  fi
}

# =============================================================================
# 生成配置
# =============================================================================
sub_add(){
  local raw=$1 label=$2 probe=${3:-1} p
  p=$(norm_path "$raw")
  if [[ -z $p ]]; then
    warn "$label 路径为空或为 /（会与站点根冲突），已跳过；请在面板里设置 /sub-xxxx/ 形式的路径"
    return 0
  fi
  if ! valid_path "$p"; then
    warn "$label 路径含非法字符，已跳过: $raw"
    return 0
  fi
  if [[ -n $PANEL_BASE && $p == "$PANEL_BASE" ]]; then
    warn "$label 路径与面板路径相同（/$p/），已跳过以避免 Nginx 冲突"
    return 0
  fi
  if [[ -n ${SUB_SEEN[$p]:-} ]]; then
    return 0
  fi
  SUB_SEEN[$p]=1
  SUB_LOCS+=("$p|$label|$probe")
}

build_sub_locations(){
  local entry rest paths='' probes=''
  SUB_LOCS=()
  SUB_SEEN=()
  SUB_PATH_LIST=''
  SUB_PROBE_PATHS=''
  SUB_PATH_DISPLAY=''
  (( SUB_ENABLED )) || return 0

  sub_add "$SUB_PATH_RAW" '订阅 raw'
  (( SUB_JSON_ENABLED )) && sub_add "$SUB_JSON_PATH_RAW" '订阅 JSON'
  if (( SUB_CLASH_ENABLED )); then
    sub_add "$SUB_CLASH_PATH_RAW" '订阅 Clash'
    sub_add 'mihomo' '订阅 Mihomo 别名' 0
  fi

  for entry in "${SUB_LOCS[@]}"; do
    paths+="/${entry%%|*}/ "
    rest=${entry#*|}
    if [[ ${rest##*|} == 1 ]]; then
      probes+="/${entry%%|*}/ "
    fi
  done
  SUB_PATH_LIST=$(trim "$paths")
  SUB_PROBE_PATHS=$(trim "$probes")
  if [[ -n ${SUB_LOCS[0]:-} ]]; then
    SUB_PATH_DISPLAY="/${SUB_LOCS[0]%%|*}/"
  fi
}

build_outputs(){
  build_sub_locations

  # 面板/订阅的展示与探测地址（写在配置注释里，需要先算出来）
  PANEL_PROBE_URL="$PANEL_SCHEME://$PANEL_HOST:$WEB_PORT$PANEL_PATH"
  if (( SUB_ENABLED )) && [[ -n $SUB_PATH_DISPLAY ]]; then
    SUB_PROBE_URL="$SUB_SCHEME://$SUB_HOST:$SUB_PORT$SUB_PATH_DISPLAY"
    SUB_SUMMARY="$SUB_HOST:$SUB_PORT，路径 ${SUB_PATH_LIST:-无}"
    if (( SUB_HTTPS )); then SUB_SUMMARY+='（后端 TLS）'; fi
  elif (( SUB_ENABLED )); then
    SUB_SUMMARY="$SUB_HOST:$SUB_PORT（未配置有效路径）"
  else
    SUB_SUMMARY='未启用'
  fi

  NGINX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  [[ -n $NGINX_VER ]] || die "无法获取 Nginx 版本（nginx -v 失败）"
  if ver_ge "$NGINX_VER" '1.25.1'; then
    HTTP2_MODERN=1
    HTTP2_SUMMARY='http2 on'
  else
    HTTP2_MODERN=0
    HTTP2_SUMMARY='listen ... http2'
  fi

  if (( NGINX_OWNS_443 )); then
    if (( HTTP2_MODERN )); then
      TLS_LISTEN_BLOCK=$'    listen 443 ssl;\n    http2 on;'
    else
      TLS_LISTEN_BLOCK='    listen 443 ssl http2;'
    fi
  else
    if (( XVER > 0 )); then
      if (( HTTP2_MODERN )); then
        TLS_LISTEN_BLOCK=$'    listen 127.0.0.1:8443 ssl proxy_protocol;\n    http2 on;'
      else
        TLS_LISTEN_BLOCK='    listen 127.0.0.1:8443 ssl http2 proxy_protocol;'
      fi
    else
      if (( HTTP2_MODERN )); then
        TLS_LISTEN_BLOCK=$'    listen 127.0.0.1:8443 ssl;\n    http2 on;'
      else
        TLS_LISTEN_BLOCK='    listen 127.0.0.1:8443 ssl http2;'
      fi
    fi
  fi

  REALIP_BLOCK=''
  if (( XVER > 0 )); then
    REALIP_BLOCK=$'    real_ip_header proxy_protocol;\n    real_ip_recursive on;'
  fi

  PANEL_SSL_BLOCK=''
  if (( PANEL_HTTPS )); then
    PANEL_SSL_BLOCK=$'        proxy_ssl_verify off;\n        proxy_ssl_server_name on;'
  fi

  PANEL_REDIRECT_BLOCK=$(cat <<EOF
        proxy_redirect $PANEL_SCHEME://$PANEL_HOST:$WEB_PORT/ https://\$host/;
EOF
)

  if (( SPEEDTEST_ENABLED )); then
    ROOT_BLOCK=$(cat <<'NGINX'
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_intercept_errors on;
        error_page 404 = @speedtest_fallback;
    }
    location @speedtest_fallback {
        return 302 https://$host/;
    }
NGINX
)
  elif [[ -n $PANEL_BASE ]]; then
    ROOT_BLOCK=$(cat <<'NGINX'
    location / {
        default_type text/html;
        return 200 '<html><body><h1>OK</h1></body></html>';
    }
NGINX
)
  else
    ROOT_BLOCK=''
  fi

  # 主站配置
  cat > "$TMP/default" <<EOF
# $MAIN_MARK — 由 3x-ui 数据库配置自动生成，手改会被下次适配覆盖
# 面板后端: $PANEL_SCHEME://$PANEL_HOST:$WEB_PORT$PANEL_PATH
# 订阅服务: $SUB_SUMMARY
# 443: $PORT_443_SUMMARY
server {
    listen 80 default_server;
    listen 8080 default_server;
    listen 8000 default_server;
    server_name $DOMAIN _;
    root "$WEBROOT";
    location /.well-known/acme-challenge/ {}
    location / { return 301 https://$DOMAIN/; }
}
server {
$TLS_LISTEN_BLOCK
    server_name $DOMAIN _;
    ssl_certificate "$CERT_FILE";
    ssl_certificate_key "$CERT_KEY";
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
$REALIP_BLOCK
$ROOT_BLOCK
    # 3x-ui 面板：只允许经 Nginx 反代，面板本身应只监听本机
    location $PANEL_LOC {
        proxy_pass $PANEL_SCHEME://$PANEL_HOST:$WEB_PORT;
$PANEL_SSL_BLOCK
$PANEL_REDIRECT_BLOCK
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 64m;
        proxy_read_timeout 300s;
    }
    include "$SUB_CONF";
}
EOF

  # 订阅片段
  {
    printf '# %s\n' "$SUB_MARK"
    if (( SUB_ENABLED )); then
      printf '# 3x-ui 订阅后端: %s://%s:%s\n' "$SUB_SCHEME" "$SUB_HOST" "$SUB_PORT"
      printf '# 由面板设置 subPath/subJsonPath/subClashPath 生成；改完再跑一次适配脚本\n'
    else
      printf '# 订阅服务在 3x-ui 中未启用，本文件不生成任何 location\n'
    fi
    local entry loc label rest
    for entry in "${SUB_LOCS[@]}"; do
      loc="/${entry%%|*}"
      rest=${entry#*|}
      label=${rest%%|*}
      cat <<EOF

# $label
location $loc {
    proxy_pass $SUB_SCHEME://$SUB_HOST:$SUB_PORT;
    proxy_redirect $SUB_SCHEME://$SUB_HOST:$SUB_PORT/ https://\$host/;
    proxy_redirect https://$SUB_HOST:$SUB_PORT/ https://\$host/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_read_timeout 60s;
}
EOF
    done
  } > "$TMP/sub-proxy.conf"

  # 证书续期 hook
  {
    printf '#!/bin/sh\n'
    printf '# %s\n' "$HOOK_MARK"
    printf '# certbot 续期后重载 Nginx；面板/订阅从磁盘加载证书时需要重启 x-ui。\n'
    printf 'systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true\n'
    if (( PANEL_HTTPS || SUB_HTTPS )); then
      printf 'systemctl restart x-ui 2>/dev/null || true\n'
    fi
  } > "$TMP/reload-hook.sh"
}

# =============================================================================
# 计划展示 / 差异
# =============================================================================
show_plan(){
  local nginx_state xui_state
  if svc_active nginx; then nginx_state='运行中'; else nginx_state='未运行（将启动）'; fi
  if (( XUI_INSTALLED == 0 )); then
    xui_state='未安装（跳过服务管理）'
  elif ! svc_active x-ui; then
    xui_state='未运行（将启动）'
  elif (( XUI_DRIFT )); then
    if (( XUI_NEEDS_SERVICE )); then
      xui_state='运行中但与配置不符（将重启）'
    else
      xui_state='运行中但与配置不符（--restart-x-ui=never，不重启）'
    fi
  else
    xui_state='运行中且与配置一致'
  fi

  cat <<EOF
========== 3x-ui 当前配置 ==========
域名:        $DOMAIN
证书:        $CERT_FILE
             $CERT_SOURCE；到期 $CERT_EXPIRY
面板:        $PANEL_SCHEME://$PANEL_HOST:$WEB_PORT$PANEL_PATH（webListen=${WEB_LISTEN:-0.0.0.0}）
订阅:        $SUB_SUMMARY
443:         $PORT_443_SUMMARY
测速:        $SPEEDTEST_SUMMARY
Nginx:       $NGINX_VER（$HTTP2_SUMMARY）
服务:        nginx=$nginx_state；x-ui=$xui_state
EOF
  if (( ${#CHANGED_FILES[@]} )); then
    printf '将更新:\n'
    local f
    for f in "${CHANGED_FILES[@]}"; do printf '  - %s\n' "$f"; done
  else
    printf '将更新:      无（生成结果与现有文件一致）\n'
  fi
}

show_diff(){
  local new=$1 old=$2
  printf '\n--- %s ---\n' "$old"
  if [[ ! -f $old ]]; then
    printf '（新文件）\n'
    sed 's/^/  + /' "$new"
    return 0
  fi
  diff -u "$old" "$new" 2>/dev/null | sed 's/^/  /' || true
}

show_diffs(){
  (( ${#CHANGED_FILES[@]} )) || return 0
  local new old
  for new in "$TMP/default" "$TMP/sub-proxy.conf" "$TMP/reload-hook.sh"; do
    case $new in
      "$TMP/default") old=$MAIN_CONF ;;
      "$TMP/sub-proxy.conf") old=$SUB_CONF ;;
      *) old=$HOOK_FILE ;;
    esac
    if [[ ! -f $old ]] || ! cmp -s "$new" "$old"; then
      show_diff "$new" "$old"
    fi
  done
}

compute_changes(){
  CHANGED_FILES=()
  if [[ ! -f $MAIN_CONF ]] || ! cmp -s "$TMP/default" "$MAIN_CONF"; then
    CHANGED_FILES+=("$MAIN_CONF")
  fi
  if [[ ! -f $SUB_CONF ]] || ! cmp -s "$TMP/sub-proxy.conf" "$SUB_CONF"; then
    CHANGED_FILES+=("$SUB_CONF")
  fi
  if [[ ! -f $HOOK_FILE ]] || ! cmp -s "$TMP/reload-hook.sh" "$HOOK_FILE"; then
    CHANGED_FILES+=("$HOOK_FILE")
  fi
}

# =============================================================================
# Nginx 接管检查 / 冲突提示
# =============================================================================
takeover_allowed(){
  local f=$1
  grep -qF "$MAIN_MARK" "$f" 2>/dev/null && return 0
  # 兼容 deploy_3xui_nginx_reality.sh 生成的配置
  grep -qF 'root /var/www/certbot;' "$f" 2>/dev/null \
    && grep -qF 'sub-proxy.conf;' "$f" 2>/dev/null \
    && grep -qE 'listen 127\.0\.0\.1:8443 ssl' "$f" 2>/dev/null
}

preflight_conflicts(){
  local f
  if [[ -f $MAIN_CONF ]] && ! grep -qF "$MAIN_MARK" "$MAIN_CONF" 2>/dev/null; then
    if takeover_allowed "$MAIN_CONF"; then
      warn "检测到 deploy 脚本生成的 Nginx 配置，将直接接管（先备份）"
    elif (( FORCE )); then
      warn "现有 $MAIN_CONF 不是本脚本生成的，--force 已允许覆盖（先备份）"
    else
      TAKEOVER_BLOCKED=1
    fi
  fi
  for f in "$NGINX_DIR"/sites-enabled/* "$NGINX_DIR"/conf.d/*.conf; do
    [[ -e $f ]] || continue
    [[ $f == "$NGINX_DIR/sites-enabled/default" ]] && continue
    if grep -qE 'listen[^;]*default_server' "$f" 2>/dev/null; then
      warn "$f 也声明了 default_server，nginx -t 可能冲突；如失败请先停用该站点"
    fi
  done
}

# =============================================================================
# 应用
# =============================================================================
write_file(){
  local src=$1 dst=$2 mode=$3 dir tmp
  dir=$(dirname "$dst")
  mkdir -p "$dir" 2>/dev/null || die "无法创建目录: $dir"
  tmp="${dst}.tmp.$$"
  cp -f "$src" "$tmp" || die "写入失败: $tmp"
  chmod "$mode" "$tmp" 2>/dev/null || true
  chown root:root "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dst" || die "替换失败: $dst"
}

backup_path(){
  local src=$1 name=$2
  [[ -e $src || -L $src ]] || return 0
  cp -a "$src" "$BK/$name" 2>/dev/null || warn "备份失败: $src"
}

backup_db(){
  (( BACKUP_DB )) || return 0
  if have sqlite3; then
    if sqlite3 "$XUI_DB" '.timeout 5000' ".backup '$BK/x-ui.db'" >/dev/null 2>&1; then
      return 0
    fi
  fi
  cp -a "$XUI_DB" "$BK/x-ui.db" 2>/dev/null || warn "备份 x-ui.db 失败"
}

ensure_site_enabled(){
  LINK="$NGINX_DIR/sites-enabled/default"
  mkdir -p "$NGINX_DIR/sites-enabled" 2>/dev/null || die "无法创建 $NGINX_DIR/sites-enabled"
  chmod 755 "$NGINX_DIR/sites-enabled" 2>/dev/null || true
  if [[ -L $LINK ]]; then
    local target
    target=$(readlink "$LINK" 2>/dev/null || true)
    if [[ $target != "$MAIN_CONF" ]]; then
      warn "sites-enabled/default 原指向 $target，将改为 $MAIN_CONF（已备份）"
      backup_path "$LINK" sites-enabled-default
      LINK_REPLACED=1
    fi
    ln -sfn "$MAIN_CONF" "$LINK" || die "无法更新软链: $LINK"
  elif [[ -e $LINK ]]; then
    backup_path "$LINK" sites-enabled-default
    LINK_REPLACED=1
    rm -f "$LINK" || die "无法移除 $LINK"
    ln -sfn "$MAIN_CONF" "$LINK" || die "无法创建软链: $LINK"
  else
    ln -sfn "$MAIN_CONF" "$LINK" || die "无法创建软链: $LINK"
    LINK_CREATED=1
  fi
}

restore_backup(){
  (( ROLLBACK_ARMED )) || return 0
  if [[ -f $BK/default ]]; then cp -a "$BK/default" "$MAIN_CONF" 2>/dev/null || true
  else rm -f "$MAIN_CONF" 2>/dev/null || true; fi
  if [[ -f $BK/sub-proxy.conf ]]; then cp -a "$BK/sub-proxy.conf" "$SUB_CONF" 2>/dev/null || true
  else rm -f "$SUB_CONF" 2>/dev/null || true; fi
  if [[ -f $BK/renewal-hook.sh ]]; then cp -a "$BK/renewal-hook.sh" "$HOOK_FILE" 2>/dev/null || true
  else rm -f "$HOOK_FILE" 2>/dev/null || true; fi
  if (( LINK_REPLACED )) && [[ -e $BK/sites-enabled-default || -L $BK/sites-enabled-default ]]; then
    rm -f "$LINK" 2>/dev/null || true
    mv -f "$BK/sites-enabled-default" "$LINK" 2>/dev/null || true
  elif (( LINK_CREATED )); then
    rm -f "$LINK" 2>/dev/null || true
  fi
  ROLLBACK_ARMED=0
  if have nginx && nginx -t >/dev/null 2>&1; then
    if have systemctl && systemctl is-active --quiet nginx 2>/dev/null; then
      systemctl reload nginx >/dev/null 2>&1 || true
    else
      nginx -s reload >/dev/null 2>&1 || true
    fi
  fi
  warn "已回滚到备份: $BK"
}

nginx_test(){
  local out
  if out=$(nginx -t 2>&1); then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out" >&2
  return 1
}

reload_nginx(){
  if have systemctl; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
      if systemctl reload nginx 2>/dev/null; then return 0; else return 1; fi
    fi
    if systemctl start nginx 2>/dev/null; then return 0; else return 1; fi
  fi
  if nginx -s reload 2>/dev/null; then return 0; fi
  return 1
}

apply(){
  if (( ${#CHANGED_FILES[@]} == 0 )); then
    info '配置文件无变化，跳过写入'
    return 0
  fi

  BK="$BACKUP_ROOT/backup-3xui-sync-$(date +%F-%H%M%S)"
  mkdir -p "$BK" 2>/dev/null || die "无法创建备份目录: $BK"
  chmod 700 "$BK" 2>/dev/null || true
  backup_path "$MAIN_CONF" default
  backup_path "$SUB_CONF" sub-proxy.conf
  backup_path "$HOOK_FILE" renewal-hook.sh
  backup_db

  ROLLBACK_ARMED=1
  # umask 077 会把新建目录建成 700；ACME webroot 需要 www-data 可读
  mkdir -p "$WEBROOT" 2>/dev/null || warn "无法创建 ACME webroot: $WEBROOT"
  chmod 755 "$WEBROOT" 2>/dev/null || true
  mkdir -p "$(dirname "$SUB_CONF")" 2>/dev/null || true
  chmod 755 "$(dirname "$SUB_CONF")" 2>/dev/null || true
  write_file "$TMP/default" "$MAIN_CONF" 0644
  write_file "$TMP/sub-proxy.conf" "$SUB_CONF" 0644
  write_file "$TMP/reload-hook.sh" "$HOOK_FILE" 0755
  ensure_site_enabled

  if ! nginx_test; then
    err 'nginx -t 校验失败，配置已回滚，Nginx 未重载'
    restore_backup
    exit 1
  fi

  if (( DO_RELOAD )); then
    if ! reload_nginx; then
      err 'Nginx 重载/启动失败（端口被占用？），配置已回滚'
      restore_backup
      exit 1
    fi
    NGINX_RELOADED=1
    info 'Nginx 已重载'
  else
    warn '--no-reload：配置已写入并通过 nginx -t，但未重载；手动执行: systemctl reload nginx'
  fi
  ROLLBACK_ARMED=0
  info "配置已应用（备份: $BK）"
}

# =============================================================================
# 服务
# =============================================================================
sub_path_ok(){
  local path=$1
  [[ -n $SUB_PROBE_ID && -n $path ]] || return 1
  local code
  # ?format=info 在新版 3x-ui 上只返回信息、不记订阅拉取次数；老版本会退化成一次普通 GET
  code=$(curl -k -s -m 8 -o /dev/null -w '%{http_code}' \
    "$SUB_SCHEME://$SUB_HOST:$SUB_PORT$path$SUB_PROBE_ID?format=info" 2>/dev/null) || true
  [[ ${code:-000} == 200 ]]
}

state_sub_paths(){
  [[ -f $SYNC_STATE ]] || return 0
  sed -n 's/^SUB_PATHS=//p' "$SYNC_STATE" | head -1
}

xui_drift(){
  if ! have curl; then
    warn '缺少 curl，跳过面板/订阅运行状态探测'
    return 1
  fi
  if have ss && ! port_listening "$WEB_PORT"; then
    info "面板端口 $WEB_PORT 未监听"
    return 0
  fi
  local code
  code=$(http_code "$PANEL_PROBE_URL")
  case $code in
    000|404)
      info "面板探测 $PANEL_PROBE_URL -> HTTP $code"
      return 0
      ;;
  esac

  if (( SUB_ENABLED )); then
    if have ss && ! port_listening "$SUB_PORT"; then
      info "订阅端口 $SUB_PORT 未监听"
      return 0
    fi
    local IFS=' ' p old
    if [[ -n $SUB_PROBE_ID && -n $SUB_PROBE_PATHS ]]; then
      for p in $SUB_PROBE_PATHS; do
        if ! sub_path_ok "$p"; then
          info "订阅路径 $p 在运行中的 x-ui 里未生效（改完订阅设置后需要重启面板）"
          return 0
        fi
      done
      old=$(state_sub_paths)
      for p in $old; do
        case " $SUB_PROBE_PATHS " in *" $p "*) continue ;; esac
        case $p in */mihomo/) continue ;; esac
        if sub_path_ok "$p"; then
          info "旧订阅路径 $p 仍在生效（x-ui 路由未重载）"
          return 0
        fi
      done
    elif [[ -f $SYNC_STATE ]]; then
      old=$(state_sub_paths)
      if [[ -n $old && " $(trim "$old") " != " $(trim "$SUB_PATH_LIST") " ]]; then
        info '订阅路径已变化且没有可用 subId 校验，需要重启 x-ui 重载路由'
        return 0
      fi
    fi
  fi
  return 1
}

detect_xui_service_state(){
  if (( XUI_INSTALLED == 0 )); then
    XUI_DRIFT=0
    XUI_NEEDS_SERVICE=0
    return 0
  fi
  if ! svc_active x-ui; then
    XUI_DRIFT=1
    XUI_NEEDS_SERVICE=1
    return 0
  fi
  if xui_drift; then XUI_DRIFT=1; else XUI_DRIFT=0; fi
  XUI_NEEDS_SERVICE=$XUI_DRIFT
  case $RESTART_XUI in
    always) XUI_NEEDS_SERVICE=1 ;;
    never) XUI_NEEDS_SERVICE=0 ;;
    auto) ;;
  esac
}

ensure_xui(){
  if (( XUI_INSTALLED == 0 )); then
    warn "未检测到 $XUI_BIN，跳过 x-ui 服务管理"
    return 0
  fi
  if ! have systemctl; then
    warn '无 systemd，跳过 x-ui 服务管理'
    return 0
  fi

  if ! svc_active x-ui; then
    info 'x-ui 未运行，启动中'
    if ! systemctl start x-ui; then
      err 'x-ui 启动失败，请查看: journalctl -u x-ui -n 50 --no-pager'
      exit 1
    fi
    wait_port "$WEB_PORT" 20 || warn "x-ui 已启动，但端口 $WEB_PORT 在 20s 内未监听"
    XUI_RESTARTED=1
    return 0
  fi

  local restart=0
  case $RESTART_XUI in
    always) restart=1 ;;
    never) restart=0 ;;
    auto) (( XUI_DRIFT )) && restart=1 ;;
  esac

  if (( restart )); then
    info '重启 x-ui 使面板/订阅配置生效'
    if ! systemctl restart x-ui; then
      err 'x-ui 重启失败，请查看: journalctl -u x-ui -n 50 --no-pager'
      exit 1
    fi
    wait_port "$WEB_PORT" 20 || warn "x-ui 已重启，但端口 $WEB_PORT 在 20s 内未监听"
    XUI_RESTARTED=1
  else
    info 'x-ui 运行中且与配置一致，不重启'
  fi
}

ensure_speedtest(){
  if (( SPEEDTEST_ENABLED == 0 )); then
    return 0
  fi
  if [[ ! -f /etc/systemd/system/speedtest-go.service ]]; then
    return 0
  fi
  if svc_active speedtest-go; then
    info 'speedtest-go 运行中'
    return 0
  fi
  info '启动 speedtest-go'
  if systemctl start speedtest-go 2>/dev/null; then
    SPEEDTEST_STARTED=1
  else
    warn 'speedtest-go 启动失败，首页测速会返回 502'
  fi
}

# =============================================================================
# 结果检查 / 验证 / 状态
# =============================================================================
show_check(){
  local ok=1
  echo '========== 适配检查 =========='
  if [[ -f $MAIN_CONF ]] && cmp -s "$TMP/default" "$MAIN_CONF"; then
    info "主站配置: 一致 ($MAIN_CONF)"
  else
    warn "主站配置: 需要更新 ($MAIN_CONF)"
    ok=0
  fi
  if [[ -f $SUB_CONF ]] && cmp -s "$TMP/sub-proxy.conf" "$SUB_CONF"; then
    info "订阅片段: 一致 ($SUB_CONF)"
  else
    warn "订阅片段: 需要更新 ($SUB_CONF)"
    ok=0
  fi
  if [[ -f $HOOK_FILE ]] && cmp -s "$TMP/reload-hook.sh" "$HOOK_FILE"; then
    info "续期 hook: 一致 ($HOOK_FILE)"
  else
    warn "续期 hook: 需要更新 ($HOOK_FILE)"
    ok=0
  fi
  if (( TAKEOVER_BLOCKED )); then
    warn "现有主站配置不是本脚本生成的，应用时需要 --force"
    ok=0
  fi
  if svc_active nginx; then info '服务: nginx 运行中'; else warn '服务: nginx 未运行'; ok=0; fi
  if (( XUI_INSTALLED )); then
    if svc_active x-ui; then
      if (( XUI_DRIFT )); then warn '服务: x-ui 运行中但配置不一致（需要重启）'; ok=0
      else info '服务: x-ui 运行中且配置一致'; fi
    else
      warn '服务: x-ui 未运行'
      ok=0
    fi
  fi
  if (( SUB_ENABLED )) && have ss && ! port_listening "$SUB_PORT"; then
    warn "服务: 订阅端口 $SUB_PORT 未监听"
    ok=0
  fi
  if (( ok )); then
    info '结论: 已适配，无需操作'
    exit 0
  fi
  warn "结论: 需要适配，运行: bash $PROG"
  exit 1
}

report_http(){
  local label=$1 url=$2 code=$3 expect=$4
  if [[ $code == '000' ]]; then
    warn "$label: 无法访问 ($url)"
    return 0
  fi
  if [[ "|$expect|" == *"|$code|"* ]]; then
    info "$label: HTTP $code ($url)"
  else
    warn "$label: HTTP $code，预期 $expect ($url)"
  fi
}

verify(){
  echo '========== 验证 =========='
  if ! have curl; then
    warn '未安装 curl，跳过 HTTP 验证'
    return 0
  fi
  local code
  code=$(tls_curl_code '/')
  report_http '站点首页' "https://$DOMAIN/" "$code" '200|301|302'
  code=$(tls_curl_code "$PANEL_PATH")
  report_http '面板' "https://$DOMAIN$PANEL_PATH" "$code" '200|301|302|307|308|401'
  if (( SUB_ENABLED )) && [[ -n $SUB_PROBE_URL ]]; then
    code=$(http_code "$SUB_PROBE_URL")
    if [[ $code == '000' ]]; then
      warn "订阅服务: 无法访问 ($SUB_PROBE_URL)"
    else
      info "订阅服务: HTTP $code（本地直连；任何 HTTP 响应都说明在监听）"
    fi
  fi
  if (( NGINX_OWNS_443 )); then
    info '443: Nginx 直接监听（用域名访问即可）'
  elif (( REALITY_443 )); then
    if (( REALITY_FALLBACK_OK )); then
      info '443: REALITY 在用；普通浏览器回落 Nginx'
    else
      warn '443: REALITY 在使用但未回落到 Nginx，网站/面板经 443 不可达'
    fi
  fi
  if have ss; then
    ss -ltn 2>/dev/null | awk 'NR==1 || $4 ~ /:(443|8443|2053|2096|3000)$/' || true
  fi
}

write_state(){
  local dir tmp files=''
  dir=$(dirname "$SYNC_STATE")
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$SYNC_STATE.tmp.$$"
  if (( ${#CHANGED_FILES[@]} )); then files="${CHANGED_FILES[*]}"; fi
  {
    printf '# adapt_3xui_nginx.sh state — 自动生成，请勿手改\n'
    printf 'SYNCED_AT=%s\n' "$(date -Is 2>/dev/null || date '+%F %T')"
    printf 'DOMAIN=%s\n' "$DOMAIN"
    printf 'PANEL_URL=https://%s%s\n' "$DOMAIN" "$PANEL_PATH"
    printf 'PANEL_BACKEND=%s://%s:%s\n' "$PANEL_SCHEME" "$PANEL_HOST" "$WEB_PORT"
    printf 'SUB_ENABLED=%s\n' "$SUB_ENABLED"
    printf 'SUB_BACKEND=%s://%s:%s\n' "$SUB_SCHEME" "$SUB_HOST" "$SUB_PORT"
    printf 'SUB_PATHS=%s\n' "$SUB_PATH_LIST"
    printf 'REALITY_443=%s\n' "$REALITY_443"
    printf 'XVER=%s\n' "$XVER"
    printf 'CERT=%s\n' "$CERT_FILE"
    printf 'FILES=%s\n' "$files"
    printf 'FINGERPRINT=%s\n' "$FP"
  } > "$tmp" 2>/dev/null || { warn "无法写状态文件: $SYNC_STATE"; return 0; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$SYNC_STATE" 2>/dev/null || warn "无法写状态文件: $SYNC_STATE"
}

summary(){
  local nginx_state xui_state f
  echo '========== 适配完成 =========='
  printf '面板入口:   https://%s%s\n' "$DOMAIN" "$PANEL_PATH"
  if (( SUB_ENABLED )) && [[ -n $SUB_PATH_LIST ]]; then
    printf '订阅入口:   https://%s%s\n' "$DOMAIN" "$SUB_PATH_DISPLAY"
  fi
  printf '443 归属:   %s\n' "$PORT_443_SUMMARY"
  printf '证书:       %s（到期 %s）\n' "$CERT_FILE" "$CERT_EXPIRY"
  printf '变更文件:\n'
  if (( ${#CHANGED_FILES[@]} )); then
    for f in "${CHANGED_FILES[@]}"; do printf '  - %s\n' "$f"; done
  else
    printf '  （无，配置已一致）\n'
  fi
  if (( NGINX_RELOADED )); then nginx_state='已重载'; else nginx_state='未重载'; fi
  if (( XUI_RESTARTED )); then xui_state='已启动/重启'; else xui_state='未改动'; fi
  printf '服务:\n'
  printf '  nginx: %s\n' "$nginx_state"
  printf '  x-ui:  %s\n' "$xui_state"
  if (( SPEEDTEST_STARTED )); then printf '  speedtest-go: 已启动\n'; fi
  if [[ -n $BK ]]; then printf '备份:       %s\n' "$BK"; fi
  printf '日志:       %s\n' "$SYNC_LOG"
  printf '下次 3x-ui 配置变化后，重新运行: bash %s\n' "$PROG"
}

# =============================================================================
# 入口
# =============================================================================
need_commands(){
  have sqlite3 || die '缺少 sqlite3（apt-get install -y sqlite3）'
  have nginx || die '缺少 nginx'
  have openssl || die '缺少 openssl'
  have cmp || die '缺少 cmp（diffutils）'
  have diff || die '缺少 diff（diffutils）'
}

parse_args(){
  while (($#)); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      -V|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      --check) CHECK_ONLY=1; DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --force) FORCE=1 ;;
      --no-reload) DO_RELOAD=0 ;;
      --restart-x-ui) RESTART_XUI=always ;;
      --restart-x-ui=*) RESTART_XUI=${1#*=} ;;
      --speedtest) shift; [[ $# -gt 0 ]] || die '--speedtest 需要参数: auto|on|off'; SPEEDTEST_MODE=$1 ;;
      --speedtest=*) SPEEDTEST_MODE=${1#*=} ;;
      --domain) shift; [[ $# -gt 0 ]] || die '--domain 需要参数'; OPT_DOMAIN=$1 ;;
      --domain=*) OPT_DOMAIN=${1#*=} ;;
      --cert) shift; [[ $# -gt 0 ]] || die '--cert 需要参数'; OPT_CERT=$1 ;;
      --cert=*) OPT_CERT=${1#*=} ;;
      --key) shift; [[ $# -gt 0 ]] || die '--key 需要参数'; OPT_KEY=$1 ;;
      --key=*) OPT_KEY=${1#*=} ;;
      --no-backup-db) BACKUP_DB=0 ;;
      --) shift; break ;;
      *) die "未知参数: $1（用 --help 查看）" ;;
    esac
    shift
  done

  case $RESTART_XUI in auto|always|never) ;; *) die "--restart-x-ui 只支持 auto|always|never" ;; esac
  case $SPEEDTEST_MODE in auto|on|off) ;; *) die "--speedtest 只支持 auto|on|off" ;; esac
  if [[ -n $OPT_CERT && -z $OPT_KEY ]] || [[ -z $OPT_CERT && -n $OPT_KEY ]]; then
    die '--cert 与 --key 必须同时指定'
  fi
}

confirm_apply(){
  if (( ASSUME_YES )); then return 0; fi
  if [[ ! -t 0 ]]; then
    die '当前不是交互终端；请加 -y/--yes 确认，或先用 --dry-run 预览'
  fi
  local ans
  if (( ${#CHANGED_FILES[@]} )); then
    read -rp '应用以上配置并重载/重启相关服务? (y/N) ' ans
  else
    read -rp '配置无需更新；仍要检查并启动/重启相关服务? (y/N) ' ans
  fi
  ans=$(trim "$ans")
  case $ans in
    y|Y|yes|YES) return 0 ;;
    *) info '已取消，未做任何修改'; exit 0 ;;
  esac
}

main(){
  parse_args "$@"
  [[ ${EUID:-0} -eq 0 ]] || die '请用 root 运行'

  init_log
  trap on_exit EXIT
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/3xui-sync.XXXXXX") || die '无法创建临时目录'
  chmod 700 "$TMP" 2>/dev/null || true

  need_commands
  check_env_files
  check_db
  load_settings
  detect_domain_and_cert
  detect_inbounds
  detect_speedtest

  if ! nginx_path_ok "$WEBROOT"; then die "WEBROOT 含 Nginx 配置不支持的字符: $WEBROOT"; fi
  if ! nginx_path_ok "$SUB_CONF"; then die "订阅片段路径含 Nginx 配置不支持的字符: $SUB_CONF"; fi

  build_outputs
  detect_xui_service_state
  preflight_conflicts
  compute_changes
  show_plan
  show_diffs

  if (( CHECK_ONLY )); then
    show_check
  fi
  if (( DRY_RUN )); then
    info '--dry-run：未写入任何文件'
    exit 0
  fi

  if (( TAKEOVER_BLOCKED )); then
    die "现有 $MAIN_CONF 不是本脚本生成的；确认要接管请加 --force（会先备份）"
  fi

  confirm_apply
  acquire_lock
  apply

  if (( DO_RELOAD )); then
    ensure_xui
    ensure_speedtest
    verify
  else
    info '--no-reload：跳过服务重载与在线验证'
  fi
  write_state
  summary
}

main "$@"
