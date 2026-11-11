#!/usr/bin/env bash
# =============================================================================
#  deploy-proxy.sh — 3x-ui + nginx (единая точка входа) + MTProto для Telegram
#
#  Запуск на ЧИСТОМ сервере Debian/Ubuntu от root. Скрипт спросит только домен:
#      bash deploy-proxy.sh
#  или сразу:  bash deploy-proxy.sh vpn.example.com
#
#  До запуска: купите домен и создайте у регистратора A-запись  домен → IP сервера
#  (если DNS на Cloudflare — облако серое, без проксирования).
#
#  Сертификат выпускает acme.sh. Сначала пробуется проверка через порт 80.
#  Если она не проходит (частая история на российских хостингах: порт 80
#  не виден из-за рубежа), скрипт сам предложит способы через DNS:
#    — Cloudflare API-токен (продление автоматическое),
#    — одна TXT-запись руками у любого регистратора (продление тоже руками).
#
#  Повторный запуск = переустановка с НОВЫМИ ключами (старые конфиги перестанут работать).
#  Перевыпустить сертификат вручную:  proxy-cert-renew
#
#  Для запуска без вопросов (необязательно):
#    DNS_API=dns_cf CF_Token=xxx  — сразу DNS-01 (провайдеры: wiki acme.sh → dnsapi)
#    CERT_FILE=... KEY_FILE=...   — свой готовый сертификат
#    ACME_CA="letsencrypt zerossl" — какие CA пробовать и в каком порядке
#                                   (google — ещё нужны ACME_EAB_KID и ACME_EAB_HMAC)
#    FORCE=1                      — переустановить без подтверждения
#    CASCADE=0                    — не спрашивать про каскад (ставить без него)
#    CASCADE_LINK='vless://...'   — сразу с каскадом, без вопроса (ссылка в одинарных кавычках)
#    CASCADE_RU_DIRECT=0|1        — российские сайты через каскад (0) или напрямую (1)
#
#  КАСКАД (вход в РФ, выход за границей):
#      я → этот (российский) сервер → зарубежный сервер → интернет
#  Весь трафик клиентов И Telegram (MTProto) уходит отсюда на зарубежный сервер.
#  Скрипт сам спросит в начале, нужен ли каскад, и попросит вставить ссылку
#  vless:// или hysteria2:// с зарубежного сервера (например, из его
#  /root/proxy-credentials.txt). Там же спросит, пускать ли российские сайты
#  (.ru/.su/.рф, IP РФ) напрямую с этого сервера (по умолчанию — да).
#
#  Что получится (снаружи открыты только 22/tcp, 80/tcp, 443/tcp, 443/udp):
#
#   443/tcp ─ nginx stream (ssl_preread, роутинг по SNI)
#      ├─ SNI = <домен>        → Xray VLESS+TCP+Reality (Vision)       127.0.0.1:10001
#      │                           └ чужие ключи → VLESS+XHTTP+Reality 127.0.0.1:10002
#      │                               └ чужие ключи → nginx TLS       127.0.0.1:8443
#      │                                   ├ /<panel>/  → 3x-ui        127.0.0.1:2053
#      │                                   ├ /<sub>/    → подписки     127.0.0.1:2096
#      │                                   ├ /<ws>      → VLESS+WS     127.0.0.1:10003
#      │                                   └ /          → сайт-заглушка
#      ├─ SNI = MTG_DOMAIN      → MTProto (mtg, Fake-TLS)              127.0.0.1:10005
#      └─ всё остальное         → nginx TLS                            127.0.0.1:8443
#   443/udp ─ nginx stream udp  → Hysteria2 (Xray)                     127.0.0.1:10004
#    80/tcp ─ nginx: ACME HTTP-01 + редирект на https
#
#  Reality работает в режиме "steal-from-yourself": маскируется под ваш же
#  домен с настоящим сертификатом, поэтому нет несоответствия IP ↔ SNI.
#
#  Ещё переменные окружения (необязательно):
#    XUI_VERSION=v3.1.0    — версия 3x-ui (по умолчанию v3.1.0; "latest" — последняя)
#    MTG_DOMAIN=www.google.com — домен для Fake-TLS маскировки MTProto
#    SKIP_DNS_CHECK=1      — не проверять, что домен указывает на этот сервер
#    CLIENT_NAME=user      — имя клиента в панели (user-tcp, user-xhttp, user-ws, user-hy2)
# =============================================================================
set -Eeuo pipefail

# ----------------------------- параметры -------------------------------------
PANEL_PORT=2053
SUB_PORT=2096
P_REALITY_TCP=10001
P_REALITY_XHTTP=10002
P_WS=10003
P_HY2=10004
P_MTG=10005
P_CASCADE_SOCKS=10006   # socks5 внутри Xray только для mtg: Telegram → каскад
P_NGINX_TLS=8443
LINKS_LIB=/usr/local/lib/proxy-links.sh

XUI_VERSION="${XUI_VERSION:-v3.1.0}"
[[ "$XUI_VERSION" == "latest" || "$XUI_VERSION" == v* ]] || XUI_VERSION="v${XUI_VERSION}"
MTG_DOMAIN="${MTG_DOMAIN:-www.google.com}"
INFO_FILE=/root/proxy-credentials.txt
CLIENT_NAME="${CLIENT_NAME:-user}"   # имя клиента в панели (email): user-tcp, user-xhttp, ...
INBOUNDS_DIR=/root/3x-ui-inbounds
XUI_DIR=/usr/local/x-ui
XUI_DB=/etc/x-ui/x-ui.db

# сертификат
DNS_API="${DNS_API:-}"
RENEW_BIN=/usr/local/bin/proxy-cert-renew
ACME_CA="${ACME_CA:-letsencrypt zerossl}"
ACME_HOME=/root/.acme.sh
ACME="$ACME_HOME/acme.sh"
ACME_WEBROOT=/var/www/acme

# ----------------------------- утилиты ---------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_rst=$'\e[0m'
log()  { echo "${c_cyn}==>${c_rst} $*"; }
ok()   { echo "${c_grn}[ok]${c_rst} $*"; }
warn() { echo "${c_ylw}[!]${c_rst} $*" >&2; }
die()  { echo "${c_red}[x]${c_rst} $*" >&2; exit 1; }
trap 'echo "${c_red}[x] Ошибка в строке $LINENO: $BASH_COMMAND${c_rst}" >&2' ERR

# случайная строка [a-zA-Z0-9] длиной $1 (без SIGPIPE под pipefail)
rand() { openssl rand -base64 96 | tr -dc 'a-zA-Z0-9' | cut -c1-"$1"; }
rand_lower() { openssl rand -hex 32 | cut -c1-"$1"; }
new_uuid() { cat /proc/sys/kernel/random/uuid; }

# Вопросы задаём через /dev/tty: так работает и `bash deploy-proxy.sh`, и `curl ... | bash`
TTY=""; (exec </dev/tty) 2>/dev/null && TTY=/dev/tty
ask() {         # вопрос -> ответ в stdout; без терминала код 1
  [[ -n "$TTY" ]] || return 1
  local v; read -rp "$1" v <"$TTY" || return 1
  printf '%s' "$v"
}
ask_secret() {  # то же, но ввод не отображается
  [[ -n "$TTY" ]] || return 1
  local v; read -rsp "$1" v <"$TTY" || return 1
  echo >&2; printf '%s' "$v"
}

# ----------------------------- проверки --------------------------------------
[[ $EUID -eq 0 ]] || die "Запустите от root:  sudo bash deploy-proxy.sh"

POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cascade|--cascade=*|--no-ru-direct)
                    die "Флага $1 больше нет: скрипт сам спросит про каскад в начале (без вопросов: CASCADE_LINK='vless://...')" ;;
    -h|--help)      sed -n '2,/^# =====/p' "$0" 2>/dev/null; exit 0 ;;
    -*)             die "Неизвестный флаг: $1 (справка: --help)" ;;
    *)              POS+=("$1"); shift ;;
  esac
done

DOMAIN="${POS[0]:-${DOMAIN:-}}"
EMAIL="${POS[1]:-${EMAIL:-}}"
while :; do
  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="$(ask "Введите домен (например vpn.example.com): ")" \
      || die "Нет терминала для вопроса. Передайте домен аргументом: bash deploy-proxy.sh vpn.example.com"
  fi
  # прощаем типичные ошибки ввода: пробелы, https://, слэш, порт, точку в конце
  DOMAIN="${DOMAIN//[[:space:]]/}"; DOMAIN="${DOMAIN,,}"
  DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN#https://}"
  DOMAIN="${DOMAIN%%/*}"; DOMAIN="${DOMAIN%%:*}"; DOMAIN="${DOMAIN%.}"
  [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] && break
  warn "Некорректный домен: '${DOMAIN}'. Нужно что-то вроде vpn.example.com"
  [[ -n "$TTY" ]] || exit 1
  DOMAIN=""
done
[[ "$MTG_DOMAIN" != "$DOMAIN" ]] || die "MTG_DOMAIN должен отличаться от вашего домена"

if [[ -f "$INFO_FILE" && "${FORCE:-0}" != "1" ]]; then
  warn "Прокси уже установлен на этом сервере (данные: $INFO_FILE)."
  warn "Переустановка создаст НОВЫЕ ключи, старые конфиги у всех клиентов перестанут работать."
  a="$(ask "Переустановить? [y/N]: ")" || die "Уже установлено. Для переустановки без вопроса: FORCE=1"
  case "$a" in
    y|Y|yes|д|Д|да|Да) ;;
    *) echo "Ничего не меняю. Текущие данные: cat $INFO_FILE"; exit 0 ;;
  esac
fi

# ----------------------------- каскад: вопросы -------------------------------
# Спрашиваем сразу, чтобы дальше установка шла без участия человека.
# Ссылку вставляют в ответ на вопрос, поэтому shell её не режет на '&' и кавычки не нужны.
CASCADE_LINK="${CASCADE_LINK:-}"
CASCADE_RU_DIRECT="${CASCADE_RU_DIRECT:-}"
CASCADE_OB=""; CASCADE_OK=0; CASCADE_HOST=""; CASCADE_PORT=""

cascade_link_ok() {  # ссылка -> 0, если похожа на годную; причину пишет в stderr
  local l="$1"
  [[ "$l" =~ ^(vless|hysteria2|hy2):// ]] || { warn "Нужна ссылка vless:// или hysteria2://"; return 1; }
  [[ "${l#*://}" == *@* ]] || { warn "В ссылке нет части до @ (id или пароль)"; return 1; }
  if [[ "$l" == vless://* && "$l" != *\?* ]]; then
    warn "В ссылке нет параметров после '?'. Скопируйте её целиком"; return 1
  fi
  return 0
}

ask_cascade_link() {  # спрашивает ссылку, пока не введут годную; пустой ввод = без каскада
  local l
  while :; do
    l="$(ask "  Ссылка с зарубежного сервера (Enter — без каскада): ")" || { CASCADE_LINK=""; return 0; }
    l="${l//[[:space:]]/}"
    if [[ -z "$l" ]]; then CASCADE_LINK=""; return 0; fi
    if cascade_link_ok "$l"; then CASCADE_LINK="$l"; return 0; fi
  done
}

if [[ -n "$CASCADE_LINK" ]]; then
  CASCADE_LINK="${CASCADE_LINK//[[:space:]]/}"
  cascade_link_ok "$CASCADE_LINK" \
    || die "CASCADE_LINK не годится (см. выше). Задавайте в одинарных кавычках: CASCADE_LINK='vless://...'"
elif [[ -n "$TTY" && "${CASCADE:-}" != 0 ]]; then
  cat >&2 <<'EOF'

  Каскад (вход в РФ, выход за границей):
      я → этот сервер → зарубежный сервер → интернет
  Весь трафик клиентов и Telegram пойдёт отсюда на зарубежный сервер.
  Понадобится ссылка vless:// или hysteria2:// с зарубежного сервера
  (например, из его /root/proxy-credentials.txt).
EOF
  a="$(ask "Подключить каскад? [y/N]: ")" || a=""
  case "$a" in
    y|Y|yes|д|Д|да|Да) ask_cascade_link ;;
  esac
fi

if [[ -n "$CASCADE_LINK" && -z "$CASCADE_RU_DIRECT" ]]; then
  a="$(ask "Российские сайты (.ru/.su/.рф, IP РФ) пускать напрямую с этого сервера, а не через заграницу? [Y/n]: ")" || a=""
  case "$a" in
    n|N|no|нет|Нет) CASCADE_RU_DIRECT=0 ;;
    *)              CASCADE_RU_DIRECT=1 ;;
  esac
fi
[[ "$CASCADE_RU_DIRECT" == 0 ]] || CASCADE_RU_DIRECT=1
if [[ -n "$CASCADE_LINK" ]]; then ok "Каскад будет настроен"; else ok "Без каскада: выход в интернет прямо с этого сервера"; fi

if [[ -n "${CERT_FILE:-}${KEY_FILE:-}" ]]; then
  [[ -s "${CERT_FILE:-}" && -s "${KEY_FILE:-}" ]] || die "CERT_FILE и KEY_FILE должны указывать на существующие файлы"
fi

SSL_DIR="/etc/ssl/proxy/$DOMAIN"
CERT="$SSL_DIR/fullchain.pem"
KEY="$SSL_DIR/privkey.pem"

. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]] \
  || die "Поддерживаются только Debian/Ubuntu (обнаружено: ${PRETTY_NAME:-unknown})"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "Архитектура $(uname -m) не поддерживается скриптом" ;;
esac

# ----------------------------- пакеты ----------------------------------------
log "Устанавливаю пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl jq openssl sqlite3 tar ca-certificates ufw nginx cron iproute2 >/dev/null
apt-get install -y libnginx-mod-stream >/dev/null 2>&1 || true
apt-get install -y qrencode >/dev/null 2>&1 || true   # QR-код подписки в конце (необязательно)
systemctl enable --now cron >/dev/null 2>&1 || true
ok "Пакеты установлены"

# ----------------------------- разбор ссылок (общий код) ---------------------
# Нужен и этому скрипту (каскад), и proxy-selftest, поэтому лежит отдельным файлом.
mkdir -p "$(dirname "$LINKS_LIB")"
cat > "$LINKS_LIB" <<'LIB_EOF'
# proxy-links.sh — ссылки vless:// и hysteria2:// → outbound Xray (создан deploy-proxy.sh)
# Подключается через source. Необязательные переменные: XRAY, CA_FILE, LOGLEVEL, TEST_URL.

urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

param() {  # <query> <key> -> значение (пусто, если параметра нет)
  local q="$1" k="$2" kv
  local -a kvs
  IFS='&' read -ra kvs <<<"$q"
  for kv in "${kvs[@]}"; do
    if [[ "${kv%%=*}" == "$k" ]]; then urldecode "${kv#*=}"; return 0; fi
  done
  return 0
}

tls_json() {  # sni alpn(csv) fp insecure(0/1)
  jq -nc --arg sni "$1" --arg alpn "$2" --arg fp "$3" --arg ins "${4:-0}" --arg ca "${CA_FILE:-}" '
    {serverName:$sni}
    + (if $alpn != "" then {alpn:($alpn|split(","))} else {} end)
    + (if $fp != "" then {fingerprint:$fp} else {} end)
    + (if $ins == "1" or $ins == "true" then {allowInsecure:true} else {} end)
    + (if $ca != "" then {certificates:[{usage:"verify", certificateFile:$ca}]} else {} end)'
}

# build_outbound <ссылка> [адрес] [порт] -> JSON outbound Xray, ошибки в stderr.
# Адрес и порт по умолчанию из ссылки; самотест подменяет их на 127.0.0.1:443.
build_outbound() {
  local link="$1" scheme rest cred hostport query host port
  local re6='^\[([^]]+)\](:([0-9]+))?$' re4='^([^:/]+)(:([0-9]+))?$'
  scheme="${link%%://*}"; rest="${link#*://}"; rest="${rest%%#*}"
  query=""
  if [[ "$rest" == *\?* ]]; then query="${rest#*\?}"; fi
  rest="${rest%%\?*}"; rest="${rest%/}"
  if [[ "$rest" != *@* ]]; then echo "в ссылке нет части до @ (id или пароль)" >&2; return 1; fi
  cred="${rest%@*}"; hostport="${rest##*@}"
  if [[ "$hostport" =~ $re6 ]] || [[ "$hostport" =~ $re4 ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]:-443}"
  else
    echo "не разобрал адрес сервера: $hostport" >&2; return 1
  fi
  local addr="${2:-$host}" p="${3:-$port}"

  case "$scheme" in
    vless)
      local type sec sni pbk sid fp flow path hh mode alpn svc ins enc stream
      type="$(param "$query" type)"; type="${type:-tcp}"
      sec="$(param "$query" security)"; sni="$(param "$query" sni)"
      pbk="$(param "$query" pbk)"; sid="$(param "$query" sid)"
      fp="$(param "$query" fp)"; flow="$(param "$query" flow)"
      path="$(param "$query" path)"; hh="$(param "$query" host)"
      mode="$(param "$query" mode)"; alpn="$(param "$query" alpn)"
      svc="$(param "$query" serviceName)"; ins="$(param "$query" allowInsecure)"
      enc="$(param "$query" encryption)"
      [[ -n "$sni" ]] || sni="$host"
      [[ "$type" == splithttp ]] && type=xhttp
      stream="$(jq -nc --arg net "$type" '{network:$net}')"
      case "$sec" in
        reality)
          if [[ -z "$pbk" ]]; then echo "reality-ссылка без pbk (публичного ключа)" >&2; return 1; fi
          stream="$(jq -c --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg fp "${fp:-chrome}" \
            '. + {security:"reality", realitySettings:{serverName:$sni, publicKey:$pbk, shortId:$sid, fingerprint:$fp}}' <<<"$stream")" ;;
        tls)
          stream="$(jq -c --argjson t "$(tls_json "$sni" "$alpn" "$fp" "${ins:-0}")" '. + {security:"tls", tlsSettings:$t}' <<<"$stream")" ;;
        ""|none) ;;
        *) echo "неизвестный security=$sec" >&2; return 1 ;;
      esac
      case "$type" in
        tcp|raw) ;;
        ws)
          stream="$(jq -c --arg p "${path:-/}" --arg h "$hh" '. + {wsSettings:({path:$p} + (if $h!="" then {host:$h} else {} end))}' <<<"$stream")" ;;
        httpupgrade)
          stream="$(jq -c --arg p "${path:-/}" --arg h "$hh" '. + {httpupgradeSettings:({path:$p} + (if $h!="" then {host:$h} else {} end))}' <<<"$stream")" ;;
        xhttp)
          stream="$(jq -c --arg p "${path:-/}" --arg h "$hh" --arg m "${mode:-auto}" '. + {xhttpSettings:({path:$p, mode:$m} + (if $h!="" then {host:$h} else {} end))}' <<<"$stream")" ;;
        grpc)
          stream="$(jq -c --arg s "$svc" '. + {grpcSettings:{serviceName:$s}}' <<<"$stream")" ;;
        *) echo "транспорт type=$type не поддерживается" >&2; return 1 ;;
      esac
      jq -nc --arg a "$addr" --argjson p "$p" --arg id "$cred" --arg flow "$flow" --arg enc "${enc:-none}" --argjson st "$stream" \
        '{protocol:"vless", settings:{vnext:[{address:$a, port:$p, users:[{id:$id, encryption:$enc, flow:$flow}]}]}, streamSettings:$st}'
      ;;
    hysteria2|hy2)
      local sni alpn ins obfs
      sni="$(param "$query" sni)"; alpn="$(param "$query" alpn)"
      ins="$(param "$query" insecure)"; obfs="$(param "$query" obfs)"
      if [[ -n "$obfs" ]]; then echo "hysteria2 с obfs=$obfs не поддерживается" >&2; return 1; fi
      [[ -n "$sni" ]] || sni="$host"
      jq -nc --arg a "$addr" --argjson p "$p" --arg auth "$(urldecode "$cred")" \
             --argjson t "$(tls_json "$sni" "${alpn:-h3}" "" "${ins:-0}")" \
        '{protocol:"hysteria", settings:{version:2, address:$a, port:$p},
          streamSettings:{network:"hysteria", security:"tls", tlsSettings:$t,
                          hysteriaSettings:{version:2, auth:$auth}}}'
      ;;
    *) echo "поддерживаются только vless:// и hysteria2://" >&2; return 1 ;;
  esac
}

# test_outbound <outbound-json> <локальный порт> <файл лога> -> 0, если через outbound ходит HTTP.
# Код ответа кладёт в TEST_CODE.
test_outbound() {
  local ob="$1" port="$2" logf="$3" cfg="${3%.log}.json" pid code
  TEST_CODE=000
  jq -n --argjson ob "$ob" --argjson port "$port" --arg ll "${LOGLEVEL:-warning}" \
    '{log:{loglevel:$ll}, inbounds:[{listen:"127.0.0.1", port:$port, protocol:"socks", settings:{udp:true}}],
      outbounds:[$ob]}' > "$cfg" || return 1
  "$XRAY" run -c "$cfg" </dev/null >"$logf" 2>&1 &
  pid=$!
  sleep 1.5
  code="$(env -u no_proxy -u NO_PROXY -u ALL_PROXY -u all_proxy curl -s -o /dev/null -m 12 -w '%{http_code}' \
          -x "socks5h://127.0.0.1:$port" "${TEST_URL:-http://cp.cloudflare.com/generate_204}" 2>/dev/null || true)"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  TEST_CODE="${code:-000}"
  [[ "$code" == 204 || "$code" == 200 ]]
}

xray_log_tail() {  # <файл лога> [строк] — полезный хвост лога Xray с отступом
  { grep -viE 'deprecated|started|non-443|unified platform|Reading config|^Xray ' "$1" || true; } \
    | tail -n "${2:-4}" | sed 's/^/        /'
}
LIB_EOF
chmod 644 "$LINKS_LIB"
# shellcheck source=/dev/null
. "$LINKS_LIB"

# ----------------------------- DNS -------------------------------------------
SERVER_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)"
DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
if [[ "${SKIP_DNS_CHECK:-0}" != "1" ]]; then
  [[ -n "$SERVER_IP" ]] || die "Не удалось определить внешний IP сервера (SKIP_DNS_CHECK=1 чтобы пропустить)"
  while [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; do
    warn "$DOMAIN указывает на '${DOMAIN_IP:-никуда}', а IP этого сервера ${SERVER_IP}."
    warn "У регистратора домена создайте A-запись:  ${DOMAIN} → ${SERVER_IP}"
    warn "(если DNS на Cloudflare — выключите проксирование, облако должно быть серым)"
    a="$(ask "Enter — проверить ещё раз, q — выход: ")" || exit 1
    [[ "$a" == q || "$a" == Q ]] && exit 1
    resolvectl flush-caches >/dev/null 2>&1 || true
    DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
  done
fi
ok "Домен $DOMAIN → ${DOMAIN_IP:-?}"

# Полный разбор ссылки (нужен jq, поэтому здесь). Если не вышло — спрашиваем ссылку заново.
while [[ -n "$CASCADE_LINK" ]]; do
  if CASCADE_OB="$(build_outbound "$CASCADE_LINK")"; then
    CASCADE_OB="$(jq -c '. + {tag:"cascade"}' <<<"$CASCADE_OB")"
    CASCADE_HOST="$(jq -r '.settings.vnext[0].address // .settings.address' <<<"$CASCADE_OB")"
    CASCADE_PORT="$(jq -r '.settings.vnext[0].port // .settings.port' <<<"$CASCADE_OB")"
    CASCADE_PROTO="$(jq -r '.protocol + "+" + .streamSettings.network + "+" + (.streamSettings.security // "none")' <<<"$CASCADE_OB")"
    CASCADE_IP="$(getent ahostsv4 "$CASCADE_HOST" | awk 'NR==1{print $1}' || true)"
    if [[ "$CASCADE_HOST" == "$DOMAIN" || "$CASCADE_HOST" == "$SERVER_IP" || ( -n "$SERVER_IP" && "$CASCADE_IP" == "$SERVER_IP" ) ]]; then
      err="Ссылка каскада указывает на ЭТОТ же сервер. Нужна ссылка с зарубежного сервера."
    else
      ok "Каскад: выход через ${CASCADE_HOST}:${CASCADE_PORT} (${CASCADE_PROTO})"
      break
    fi
  else
    err="Не смог разобрать ссылку каскада (причина выше)."
  fi
  CASCADE_OB=""
  [[ -n "$TTY" ]] || die "$err"
  warn "$err Вставьте другую или нажмите Enter, чтобы ставить без каскада."
  ask_cascade_link
done

# ----------------------------- секреты ---------------------------------------
PANEL_USER="admin_$(rand_lower 6)"
PANEL_PASS="$(rand 24)"
PANEL_PATH="$(rand 18)"
WS_PATH="ws-$(rand_lower 12)"
XHTTP_PATH="xh-$(rand_lower 12)"
SUB_PATH="/s-$(rand_lower 10)/"        # путь подписок (с обоих концов /)
SUB_JSON_PATH="/j-$(rand_lower 10)/"   # путь JSON-подписок
SUB_ID="$(rand_lower 16)"              # один subId на всех клиентов = одна подписка со всеми конфигами
UUID_TCP="$(new_uuid)"; UUID_XHTTP="$(new_uuid)"; UUID_WS="$(new_uuid)"
HY2_AUTH="$(rand 32)"
SID_TCP="$(openssl rand -hex 8)"; SID_XHTTP="$(openssl rand -hex 8)"
# MTProto Fake-TLS secret: ee + 16 байт + hex(домен маскировки)
MTG_SECRET="ee$(openssl rand -hex 16)$(printf '%s' "$MTG_DOMAIN" | od -An -tx1 | tr -d ' \n')"

HAS_V6=0
[[ -f /proc/net/if_inet6 && "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" == "0" ]] && HAS_V6=1

# ----------------------------- nginx: этап 1 (порт 80 + ACME) -----------------
log "Настраиваю nginx (порт 80)"
for svc in apache2 caddy; do systemctl disable --now "$svc" >/dev/null 2>&1 || true; done
rm -f /etc/nginx/sites-enabled/default
mkdir -p "$ACME_WEBROOT" "/var/www/$DOMAIN" /etc/nginx/stream.d

L6_80=""; [[ $HAS_V6 == 1 ]] && L6_80="listen [::]:80 default_server;"
cat > /etc/nginx/conf.d/10-http80.conf <<EOF
server {
    listen 80 default_server;
    ${L6_80}
    server_name _;
    server_tokens off;

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type text/plain;
    }
    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}
EOF
rm -f /etc/nginx/conf.d/20-site-tls.conf /etc/nginx/stream.d/proxy.conf
nginx -t >/dev/null 2>&1 || { nginx -t; die "Ошибка конфигурации nginx"; }
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

# ----------------------------- сертификат ------------------------------------
log "Получаю TLS-сертификат для $DOMAIN"
mkdir -p "$SSL_DIR"; chmod 700 "$SSL_DIR"

# после выпуска/продления: перечитать сертификат в nginx и Xray
RELOAD_CMD="systemctl reload nginx >/dev/null 2>&1; systemctl restart x-ui >/dev/null 2>&1; true"

ca_dir() {  # имя CA -> URL ACME directory (можно передать и сам URL)
  case "$1" in
    letsencrypt) echo https://acme-v02.api.letsencrypt.org/directory ;;
    zerossl)     echo https://acme.zerossl.com/v2/DV90 ;;
    google)      echo https://dv.acme-v02.api.pki.goog/directory ;;
    *)           echo "$1" ;;
  esac
}

install_acme() {
  if [[ -x "$ACME" ]]; then
    "$ACME" --upgrade >/dev/null 2>&1 || warn "acme.sh не обновился, работаю со старой версией"
    return 0
  fi
  local t; t="$(mktemp -d)"
  curl -fsSL --retry 3 https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz \
    | tar -xz -C "$t" || die "Не удалось скачать acme.sh с GitHub"
  local -a a=(--install --home "$ACME_HOME")
  [[ -n "$EMAIL" ]] && a+=(--accountemail "$EMAIL")
  (cd "$t"/acme.sh-* && ./acme.sh "${a[@]}") >/dev/null 2>&1 || die "Не удалось установить acme.sh"
  rm -rf "$t"
  [[ -x "$ACME" ]] || die "acme.sh не найден в $ACME_HOME"
}

register_ca() {  # CA -> 0, если ACME-аккаунт есть или создан
  local ca="$1"
  local -a reg=(--register-account --server "$ca")
  if [[ -n "$EMAIL" ]]; then reg+=(-m "$EMAIL")
  elif [[ "$ca" == zerossl ]]; then reg+=(-m "admin@${DOMAIN}")   # ZeroSSL без email не регистрирует
  fi
  if [[ "$ca" == google ]]; then
    if [[ -z "${ACME_EAB_KID:-}" || -z "${ACME_EAB_HMAC:-}" ]]; then
      warn "google: нужны ACME_EAB_KID и ACME_EAB_HMAC (выдаются в Google Cloud), пропускаю"
      return 1
    fi
    reg+=(--eab-kid "$ACME_EAB_KID" --eab-hmac-key "$ACME_EAB_HMAC")
  fi
  "$ACME" "${reg[@]}" >/dev/null 2>&1 || { warn "$ca: не удалось зарегистрировать ACME-аккаунт"; return 1; }
}

try_cas() {  # аргументы способа проверки -> 0 (и ISSUED_BY), если кто-то из CA выдал сертификат
  local ca rc
  for ca in $ACME_CA; do
    if ! curl -fsS -o /dev/null --max-time 10 "$(ca_dir "$ca")"; then
      warn "$ca: сервер недоступен с этого хоста, пропускаю"
      continue
    fi
    register_ca "$ca" || continue
    log "Запрашиваю сертификат у $ca"
    rc=0
    "$ACME" --issue --server "$ca" -d "$DOMAIN" --keylength ec-256 "$@" || rc=$?
    if [[ $rc -eq 0 || $rc -eq 2 ]]; then ISSUED_BY="$ca"; return 0; fi   # 2 = уже есть актуальный
    warn "$ca: выпуск не удался"
  done
  return 1
}

# DNS-хук для acme.sh: показывает TXT-запись, ждёт, пока человек добавит её у регистратора,
# и проверяет через публичный DNS. Без терминала (например, в cron) сразу отказывает.
write_dns_tty_hook() {
  mkdir -p "$ACME_HOME/dnsapi"
  cat > "$ACME_HOME/dnsapi/dns_tty.sh" <<'EOF'
#!/usr/bin/env sh
# dns_tty — ручная TXT-запись с подтверждением в терминале (создан deploy-proxy.sh)

dns_tty_add() {
  fulldomain="$1"; txtvalue="$2"
  if ! { true </dev/tty; } 2>/dev/null; then
    echo "dns_tty: нужен интерактивный терминал, запустите proxy-cert-renew руками" >&2
    return 1
  fi
  {
    printf '\n  Добавьте у регистратора домена DNS-запись:\n'
    printf '    Тип:      TXT\n'
    printf '    Имя:      %s\n' "$fulldomain"
    printf '    Значение: %s\n' "$txtvalue"
    printf '  Если панель сама дописывает основной домен, введите только начало имени.\n'
    printf '  Старую запись _acme-challenge с прошлого раза удалите или замените.\n\n'
  } >/dev/tty
  while :; do
    printf '  Добавили? Enter — проверить, s — продолжить без проверки, q — отмена: ' >/dev/tty
    read -r _a </dev/tty || return 1
    case "$_a" in q|Q) return 1 ;; s|S) return 0 ;; esac
    if _dns_tty_visible "$fulldomain" "$txtvalue"; then
      printf '  Запись видна в DNS, продолжаю\n' >/dev/tty
      return 0
    fi
    printf '  Пока не видна. DNS обновляется от 1 до 15 минут, подождите и нажмите Enter ещё раз.\n' >/dev/tty
  done
}

dns_tty_rm() {
  { printf '  Проверка пройдена, TXT-запись %s можно удалить.\n' "$1" >/dev/tty; } 2>/dev/null
  return 0
}

_dns_tty_visible() {  # имя значение
  for _u in "https://dns.google/resolve?name=$1&type=TXT" \
            "https://cloudflare-dns.com/dns-query?name=$1&type=TXT"; do
    _r="$(curl -fsS --max-time 8 -H 'accept: application/dns-json' "$_u" 2>/dev/null)" || continue
    case "$_r" in *"$2"*) return 0 ;; esac
  done
  return 1
}
EOF
}

cert_via_cloudflare() {
  cat >&2 <<'EOF'

  Нужен API-токен Cloudflare (домен должен обслуживаться DNS Cloudflare):
    dash.cloudflare.com → My Profile → API Tokens → Create Token → шаблон "Edit zone DNS".
    В Permissions добавьте ещё строку  Zone → Zone → Read,
    в Zone Resources выберите свой домен, создайте токен и скопируйте его.
EOF
  local t; t="$(ask_secret "  Вставьте токен (ввод скрыт): ")" || return 1
  [[ -n "$t" ]] || { warn "Пустой токен"; return 1; }
  export CF_Token="$t"   # acme.sh сохранит токен у себя для автопродления
  if try_cas --dns dns_cf; then unset CF_Token; return 0; fi
  unset CF_Token
  warn "Не вышло. Проверьте права токена и что домен действительно на DNS Cloudflare."
  return 1
}

ISSUED_BY=""; CERT_HOW=""
if [[ -n "${CERT_FILE:-}" ]]; then
  install -m 644 "$CERT_FILE" "$CERT"
  install -m 600 "$KEY_FILE" "$KEY"
  CERT_HOW="file"
  warn "Свой сертификат: автопродления НЕТ. Перед истечением замените файлы в $SSL_DIR и выполните: $RELOAD_CMD"
else
  install_acme
  write_dns_tty_hook
  if [[ -n "$DNS_API" ]]; then
    try_cas --dns "$DNS_API" || die "Не удалось получить сертификат через $DNS_API"
    CERT_HOW="auto"
  elif try_cas -w "$ACME_WEBROOT"; then
    CERT_HOW="auto"
  else
    [[ -n "$TTY" ]] || die "Проверка через порт 80 не прошла, а без терминала выбрать другой способ нельзя. Задайте DNS_API=dns_cf CF_Token=..."
    warn "Проверка через порт 80 не прошла: удостоверяющий центр не достучался до сервера."
    warn "На российских хостингах это обычное дело. Способам через DNS порт 80 не нужен."
    while [[ -z "$ISSUED_BY" ]]; do
      cat >&2 <<'EOF'

  Как получить сертификат?
    1) Через Cloudflare: домен на DNS Cloudflare, нужен API-токен. Продление автоматическое.
    2) Вручную: добавить одну TXT-запись у регистратора. Работает с любым регистратором,
       но продлевать так же руками раз в ~2 месяца (команда proxy-cert-renew).
    3) Ещё раз через порт 80 (если вы что-то поправили).
    q) Выйти.
EOF
      a="$(ask "Ваш выбор [1/2/3/q]: ")" || die "Нет ответа"
      case "$a" in
        1) cert_via_cloudflare && CERT_HOW="auto" ;;
        2) try_cas --dns dns_tty --dnssleep 5 && CERT_HOW="manual-dns" ;;
        3) try_cas -w "$ACME_WEBROOT" && CERT_HOW="auto" ;;
        q|Q) die "Отменено" ;;
        *) warn "Не понял ответ" ;;
      esac
    done
  fi
  "$ACME" --install-cert -d "$DOMAIN" --ecc \
      --fullchain-file "$CERT" --key-file "$KEY" --reloadcmd "$RELOAD_CMD" >/dev/null 2>&1 \
    || die "acme.sh не смог положить сертификат в $SSL_DIR"
  chmod 600 "$KEY"
fi

# проверяем, что сертификат годный, а не просто существует
[[ -s "$CERT" && -s "$KEY" ]] || die "Файлы сертификата не найдены"
openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" 2>/dev/null | grep -q 'does match' \
  || die "Сертификат не покрывает домен $DOMAIN"
openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null \
  || die "Сертификат истёк или истекает в ближайшие сутки"
[[ "$(openssl x509 -in "$CERT" -noout -pubkey | openssl sha256)" == "$(openssl pkey -in "$KEY" -pubout | openssl sha256)" ]] \
  || die "Приватный ключ не соответствует сертификату"
CERT_ISSUER="$(openssl x509 -in "$CERT" -noout -issuer | sed 's/^issuer= *//')"
CERT_END="$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)"
ok "Сертификат: ${CERT_ISSUER}, действует до ${CERT_END}"

# команда ручного перевыпуска
if [[ "$CERT_HOW" == file ]]; then
  cat > "$RENEW_BIN" <<EOF
#!/usr/bin/env bash
echo "Сертификат ставился из файлов, а не через acme.sh."
echo "Положите новые fullchain.pem и privkey.pem в ${SSL_DIR} и выполните:"
echo "  systemctl reload nginx && systemctl restart x-ui"
EOF
else
  cat > "$RENEW_BIN" <<EOF
#!/usr/bin/env bash
# Перевыпуск TLS-сертификата для ${DOMAIN} (создан deploy-proxy.sh)
exec "${ACME}" --renew -d "${DOMAIN}" --ecc --force
EOF
fi
chmod 755 "$RENEW_BIN"

# предупреждение при входе по SSH, если сертификат скоро истечёт
if [[ -d /etc/update-motd.d ]]; then
  cat > /etc/update-motd.d/99-proxy-cert <<EOF
#!/bin/sh
# предупреждение об истечении сертификата прокси (создан deploy-proxy.sh)
end="\$(openssl x509 -in '${CERT}' -noout -enddate 2>/dev/null | cut -d= -f2)"
[ -n "\$end" ] || exit 0
left=\$(( (\$(date -d "\$end" +%s) - \$(date +%s)) / 86400 ))
[ "\$left" -lt 20 ] && echo "[!] Сертификат прокси ${DOMAIN} истекает через \$left дн. Продлить: proxy-cert-renew"
exit 0
EOF
  chmod 755 /etc/update-motd.d/99-proxy-cert
fi

# ----------------------------- 3x-ui -----------------------------------------
log "Устанавливаю 3x-ui (${XUI_VERSION})"
if [[ "$XUI_VERSION" == "latest" ]]; then
  XUI_URL="https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-${ARCH}.tar.gz"
else
  XUI_URL="https://github.com/MHSanaei/3x-ui/releases/download/${XUI_VERSION}/x-ui-linux-${ARCH}.tar.gz"
fi
TMPD="$(mktemp -d)"
curl -fL --retry 3 -o "$TMPD/x-ui.tar.gz" "$XUI_URL" || die "Не удалось скачать 3x-ui: $XUI_URL"

systemctl stop x-ui >/dev/null 2>&1 || true
if [[ -f "$XUI_DB" ]]; then
  mv "$XUI_DB" "${XUI_DB}.bak.$(date +%s)"
  warn "Старая база 3x-ui перенесена в ${XUI_DB}.bak.*"
fi
rm -rf "$XUI_DIR"
tar -xzf "$TMPD/x-ui.tar.gz" -C /usr/local/
chmod +x "$XUI_DIR/x-ui" "$XUI_DIR"/bin/xray-linux-* 2>/dev/null || true
[[ -f "$XUI_DIR/x-ui.sh" ]] && install -m 755 "$XUI_DIR/x-ui.sh" /usr/bin/x-ui

if [[ -f "$XUI_DIR/x-ui.service.debian" ]]; then
  cp -f "$XUI_DIR/x-ui.service.debian" /etc/systemd/system/x-ui.service
elif [[ -f "$XUI_DIR/x-ui.service" ]]; then
  cp -f "$XUI_DIR/x-ui.service" /etc/systemd/system/x-ui.service
else
  cat > /etc/systemd/system/x-ui.service <<EOF
[Unit]
Description=x-ui Service
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=${XUI_DIR}/
ExecStart=${XUI_DIR}/x-ui
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi
systemctl daemon-reload

XUI_BIN="$XUI_DIR/x-ui"
XRAY_BIN="$(ls "$XUI_DIR"/bin/xray-linux-* 2>/dev/null | head -n1 || true)"
[[ -x "$XRAY_BIN" ]] || die "Не найден бинарник Xray в $XUI_DIR/bin"
XRAY="$XRAY_BIN"   # для test_outbound

# каскад проверяем до того, как на него завязать всё остальное
if [[ -n "$CASCADE_OB" ]]; then
  log "Проверяю, что через зарубежный сервер ходит трафик"
  if test_outbound "$CASCADE_OB" 20799 "$TMPD/cascade.log"; then
    ok "Зарубежный сервер отвечает"
  else
    xray_log_tail "$TMPD/cascade.log" 6
    die "Через ${CASCADE_HOST}:${CASCADE_PORT} трафик не идёт (HTTP ${TEST_CODE}). Проверьте ссылку и запустите proxy-selftest на зарубежном сервере"
  fi
fi

# учётные данные, порт и путь панели
(cd "$XUI_DIR" && "$XUI_BIN" setting -username "$PANEL_USER" -password "$PANEL_PASS" \
    -port "$PANEL_PORT" -webBasePath "$PANEL_PATH") >/dev/null
[[ -f "$XUI_DB" ]] || die "База 3x-ui не создалась ($XUI_DB)"

set_setting() {  # ключ значение — пишет прямо в settings 3x-ui (после записи нужен рестарт x-ui)
  local k="${1//\'/\'\'}" v="${2//\'/\'\'}"
  sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='$k'; INSERT INTO settings(key,value) VALUES('$k','$v');"
}
# панель и подписки слушают только localhost — снаружи всё через nginx
set_setting webListen     "127.0.0.1"
# подписки: отдаются через nginx на 443, ссылки в панели — без порта
set_setting subEnable     "true"
set_setting subJsonEnable "true"
set_setting subListen     "127.0.0.1"
set_setting subPort       "$SUB_PORT"
set_setting subPath       "$SUB_PATH"
set_setting subJsonPath   "$SUB_JSON_PATH"
set_setting subURI        "https://${DOMAIN}${SUB_PATH}"
set_setting subJsonURI    "https://${DOMAIN}${SUB_JSON_PATH}"

systemctl enable x-ui >/dev/null 2>&1
systemctl restart x-ui

# Схема локального сервиса: панель/подписки могут говорить и HTTP, и HTTPS
# (если в 3x-ui прописать сертификат). Сначала пробуем HTTPS: HTTP-сервер
# на TLS-запрос не ответит (000), а HTTPS-сервер на HTTP ответит 400 — поэтому порядок важен.
detect_scheme() {  # порт путь -> печатает https|http, пусто если не отвечает
  local c
  c="$(curl -sk -o /dev/null --max-time 3 -w '%{http_code}' "https://127.0.0.1:$1$2" || true)"
  [[ "$c" != "000" ]] && { echo https; return; }
  c="$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:$1$2" || true)"
  [[ "$c" != "000" ]] && echo http
  return 0   # не отвечает — пустой вывод, но не ошибка (иначе set -e уронит скрипт)
}
PANEL_SCHEME=""
for _ in $(seq 1 30); do
  PANEL_SCHEME="$(detect_scheme "$PANEL_PORT" "/${PANEL_PATH}/")"
  [[ -n "$PANEL_SCHEME" ]] && break
  sleep 1
done
[[ -n "$PANEL_SCHEME" ]] || die "Панель 3x-ui не запустилась: journalctl -u x-ui -n 50"
PANEL_LOCAL="${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
ok "3x-ui ${XUI_VERSION} запущена (панель: ${PANEL_SCHEME})"

# ----------------------------- ключи Reality ---------------------------------
gen_x25519() {
  local out; out="$("$XRAY_BIN" x25519)"
  PRIV="$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$out")"
  PUB="$(awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' <<<"$out")"
  [[ -n "$PRIV" && -n "$PUB" ]] || die "Не удалось сгенерировать ключи x25519"
}
gen_x25519; PRIV_TCP="$PRIV"; PUB_TCP="$PUB"
gen_x25519; PRIV_XHTTP="$PRIV"; PUB_XHTTP="$PUB"

# ----------------------------- описания инбаундов ----------------------------
SNIFF='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

client_json() { # id/auth-поле, значение, email, flow
  jq -nc --arg k "$1" --arg v "$2" --arg email "$3" --arg flow "${4:-}" --arg sub "$SUB_ID" \
    '{($k):$v, email:$email, limitIp:0, totalGB:0, expiryTime:0, enable:true,
      tgId:"", subId:$sub, comment:"", reset:0}
     + (if $k=="id" then {flow:$flow} else {} end)'
}
reality_json() { # target privkey pubkey shortId
  jq -nc --arg t "$1" --arg sni "$DOMAIN" --arg priv "$2" --arg pub "$3" --arg sid "$4" \
    '{show:false, xver:0, target:$t, serverNames:[$sni], privateKey:$priv,
      minClientVer:"", maxClientVer:"", maxTimediff:0, shortIds:[$sid],
      settings:{publicKey:$pub, fingerprint:"chrome", serverName:"", spiderX:"/"}}'
}
inbound_json() { # remark port protocol settings stream
  jq -nc --arg remark "$1" --argjson port "$2" --arg proto "$3" \
         --argjson s "$4" --argjson st "$5" --argjson sn "$SNIFF" \
    '{up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0,
      listen:"127.0.0.1", port:$port, protocol:$proto,
      settings:($s|tojson), streamSettings:($st|tojson), sniffing:($sn|tojson)}'
}

# externalProxy: в ссылках/подписках подставлять домен:443, а не 127.0.0.1:1000x
EXT_SAME="$(jq -nc --arg d "$DOMAIN" '[{forceTls:"same", dest:$d, port:443, remark:""}]')"
EXT_TLS="$(jq -nc --arg d "$DOMAIN" '[{forceTls:"tls", dest:$d, port:443, remark:""}]')"

mkdir -p "$INBOUNDS_DIR"; chmod 700 "$INBOUNDS_DIR"
rm -f "$INBOUNDS_DIR"/*.json

# 1) VLESS + TCP + Reality (Vision). Непрошедших авторизацию отдаёт в XHTTP-Reality
S="$(jq -nc --argjson c "$(client_json id "$UUID_TCP" "${CLIENT_NAME}-tcp" xtls-rprx-vision)" \
      '{clients:[$c], decryption:"none", fallbacks:[]}')"
ST="$(jq -nc --argjson r "$(reality_json "127.0.0.1:${P_REALITY_XHTTP}" "$PRIV_TCP" "$PUB_TCP" "$SID_TCP")" \
      --argjson ep "$EXT_SAME" \
      '{network:"tcp", security:"reality", externalProxy:$ep, realitySettings:$r,
        tcpSettings:{acceptProxyProtocol:false, header:{type:"none"}}}')"
inbound_json "VLESS-TCP-Reality" "$P_REALITY_TCP" vless "$S" "$ST" > "$INBOUNDS_DIR/1-vless-tcp-reality.json"

# 2) VLESS + XHTTP + Reality. Непрошедших авторизацию отдаёт в nginx (настоящий сайт)
S="$(jq -nc --argjson c "$(client_json id "$UUID_XHTTP" "${CLIENT_NAME}-xhttp")" \
      '{clients:[$c], decryption:"none", fallbacks:[]}')"
ST="$(jq -nc --argjson r "$(reality_json "127.0.0.1:${P_NGINX_TLS}" "$PRIV_XHTTP" "$PUB_XHTTP" "$SID_XHTTP")" \
      --arg p "/$XHTTP_PATH" --argjson ep "$EXT_SAME" \
      '{network:"xhttp", security:"reality", externalProxy:$ep, realitySettings:$r,
        xhttpSettings:{path:$p, host:"", mode:"auto", headers:{}}}')"
inbound_json "VLESS-XHTTP-Reality" "$P_REALITY_XHTTP" vless "$S" "$ST" > "$INBOUNDS_DIR/2-vless-xhttp-reality.json"

# 3) VLESS + WebSocket (TLS терминирует nginx)
S="$(jq -nc --argjson c "$(client_json id "$UUID_WS" "${CLIENT_NAME}-ws")" \
      '{clients:[$c], decryption:"none", fallbacks:[]}')"
ST="$(jq -nc --arg p "/$WS_PATH" --argjson ep "$EXT_TLS" \
      '{network:"ws", security:"none", externalProxy:$ep,
        wsSettings:{acceptProxyProtocol:false, path:$p, host:"", headers:{}}}')"
inbound_json "VLESS-WS-TLS" "$P_WS" vless "$S" "$ST" > "$INBOUNDS_DIR/3-vless-ws-tls.json"

# 4) Hysteria2 (UDP, TLS-сертификат из $SSL_DIR)
S="$(jq -nc --argjson c "$(client_json auth "$HY2_AUTH" "${CLIENT_NAME}-hy2")" '{version:2, clients:[$c]}')"
ST="$(jq -nc --arg sni "$DOMAIN" --arg cert "$CERT" --arg key "$KEY" --arg auth "$HY2_AUTH" \
      --argjson ep "$EXT_SAME" \
      '{network:"hysteria", security:"tls", externalProxy:$ep,
        tlsSettings:{serverName:$sni, minVersion:"1.3", maxVersion:"1.3", alpn:["h3"],
                     certificates:[{certificateFile:$cert, keyFile:$key, ocspStapling:3600,
                                    oneTimeLoading:false, usage:"encipherment", buildChain:false}],
                     settings:{allowInsecure:false, fingerprint:""}},
        hysteriaSettings:{version:2, auth:$auth, udpIdleTimeout:60}}')"
inbound_json "Hysteria2" "$P_HY2" hysteria "$S" "$ST" > "$INBOUNDS_DIR/4-hysteria2.json"

# ----------------------------- добавление через API 3x-ui ---------------------
log "Добавляю инбаунды в 3x-ui"
JAR="$(mktemp)"; CSRF=""
fetch_csrf() {  # 3x-ui v3+: GET /csrf-token; в v2.x эндпоинта нет — это нормально
  local hdr body code
  hdr="$(mktemp)"
  body="$(curl -sSk -b "$JAR" -c "$JAR" -D "$hdr" "${PANEL_LOCAL}/csrf-token" 2>/dev/null || true)"
  code="$(awk 'NR==1{print $2}' "$hdr")"
  if [[ "$code" == "200" ]]; then
    CSRF="$(jq -r '(.obj // .token // .csrfToken // .data // empty)
                   | if type=="object" then (.token // .csrfToken // empty) else . end' <<<"$body" 2>/dev/null || true)"
    [[ -z "$CSRF" ]] && CSRF="$(grep -i '^x-csrf-token:' "$hdr" | cut -d' ' -f2- | tr -d '\r' || true)"
    [[ -z "$CSRF" && "${body:0:1}" != "{" ]] && CSRF="$(tr -d '\r\n" ' <<<"$body")"
  fi
  rm -f "$hdr"
}
panel_post() {  # путь, далее аргументы curl
  local path="$1"; shift
  local -a h=(-H "Origin: ${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}")
  [[ -n "$CSRF" ]] && h+=(-H "X-CSRF-Token: $CSRF")
  curl -sSk -b "$JAR" -c "$JAR" "${h[@]}" -X POST "${PANEL_LOCAL}${path}" "$@" 2>/dev/null || true
}

# Каскад: берём из панели текущий шаблон Xray (дефолтный для этой версии 3x-ui) и дописываем:
#  - outbound "cascade" первым в списке — так он становится маршрутом по умолчанию;
#  - inbound "mtg-in" (socks5 на 127.0.0.1) и правило "mtg-in → cascade" для Telegram;
#  - если на вопрос в начале ответили, что российские сайты напрямую (по умолчанию):
#    .ru/.su/.рф и IP РФ идут напрямую (outbound "direct").
# Шаблон пишется в базу (settings.xrayTemplateConfig), применяется рестартом x-ui.
apply_cascade() {
  local resp tmpl new geo=0
  [[ -f "$XUI_DIR/bin/geoip.dat" ]] && geo=1
  resp="$(panel_post /panel/xray/)"
  tmpl="$(jq -c '.obj | (if type=="string" then fromjson else . end) | .xraySetting
                 | (if type=="string" then fromjson else . end)' <<<"$resp" 2>/dev/null || true)"
  if [[ -z "$tmpl" || "$tmpl" == null ]]; then
    warn "Панель не отдала шаблон Xray. Ответ: ${resp:0:200}"
    return 1
  fi
  new="$(jq -c --argjson ob "$CASCADE_OB" --argjson port "$P_CASCADE_SOCKS" \
              --argjson ru "$CASCADE_RU_DIRECT" --argjson geo "$geo" '
    .outbounds = [$ob] + ((.outbounds // []) | map(select(.tag != "cascade")))
    | (if any(.outbounds[]; .tag == "direct") then .
       else .outbounds += [{tag:"direct", protocol:"freedom", settings:{}}] end)
    | .inbounds = ((.inbounds // []) | map(select(.tag != "mtg-in")))
        + [{tag:"mtg-in", listen:"127.0.0.1", port:$port, protocol:"socks",
            settings:{auth:"noauth", udp:false}}]
    | .routing.rules = [{type:"field", inboundTag:["mtg-in"], outboundTag:"cascade"}]
        + ((.routing.rules // []) | map(select(.inboundTag != ["mtg-in"])))
        + (if $ru == 1 then
             [{type:"field", outboundTag:"direct",
               domain:["regexp:\\.ru$", "regexp:\\.su$", "regexp:\\.xn--p1ai$"]}]
             + (if $geo == 1 then [{type:"field", outboundTag:"direct", ip:["geoip:ru"]}] else [] end)
           else [] end)
  ' <<<"$tmpl")" || { warn "Не смог собрать шаблон Xray с каскадом"; return 1; }
  jq . <<<"$new" > "$INBOUNDS_DIR/xray-template-cascade.json"
  set_setting xrayTemplateConfig "$(jq . <<<"$new")"
}

API_OK=1
fetch_csrf
resp="$(panel_post /login --data-urlencode "username=$PANEL_USER" --data-urlencode "password=$PANEL_PASS")"
if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
  API_OK=0
  warn "Не удалось войти в API панели. Ответ: ${resp:0:200}"
else
  fetch_csrf   # токен может быть привязан к новой сессии
  for f in "$INBOUNDS_DIR"/*.json; do
    resp="$(panel_post /panel/api/inbounds/add -H 'Content-Type: application/json' --data-binary @"$f")"
    if jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
      ok "Добавлен: $(jq -r .remark "$f")"
    else
      API_OK=0
      warn "Не добавлен $(basename "$f"): $(jq -r '.msg // empty' <<<"$resp" 2>/dev/null || echo "${resp:0:200}")"
    fi
  done
  if [[ -n "$CASCADE_OB" ]]; then
    if apply_cascade; then CASCADE_OK=1; ok "Каскад прописан в шаблон Xray"; fi
  fi
fi
rm -f "$JAR"
if [[ -n "$CASCADE_OB" && $CASCADE_OK != 1 ]]; then
  warn "КАСКАД НЕ ВКЛЮЧЁН: трафик пойдёт в интернет прямо с этого сервера."
  warn "Готовый шаблон можно вставить вручную: панель → Xray Configs → Advanced (см. ${INBOUNDS_DIR}/)"
fi
systemctl restart x-ui

# схема сервера подписок (HTTP или HTTPS — зависит от того, задан ли сертификат в 3x-ui)
SUB_SCHEME=""
for _ in $(seq 1 20); do
  SUB_SCHEME="$(detect_scheme "$SUB_PORT" "$SUB_PATH")"
  [[ -n "$SUB_SCHEME" ]] && break
  sleep 1
done
if [[ -z "$SUB_SCHEME" ]]; then
  SUB_SCHEME=http
  warn "Сервер подписок не ответил на :$SUB_PORT — в nginx прописан http, проверьте настройки подписки в панели"
fi
# панель тоже переопределяем после рестарта
PANEL_SCHEME="$(detect_scheme "$PANEL_PORT" "/${PANEL_PATH}/")"; PANEL_SCHEME="${PANEL_SCHEME:-http}"

# ----------------------------- MTProto (mtg) ---------------------------------
log "Устанавливаю MTProto-прокси для Telegram (mtg)"
MTG_URL="$(curl -fsSL https://api.github.com/repos/9seconds/mtg/releases/latest \
  | jq -r --arg a "linux-${ARCH}" \
    '[.assets[] | select(.name|contains($a)) | select(.name|endswith(".tar.gz"))][0].browser_download_url // empty' || true)"
[[ -n "$MTG_URL" ]] || die "Не удалось найти релиз mtg для linux-${ARCH}"
mkdir -p "$TMPD/mtg"
curl -fsSL --retry 3 "$MTG_URL" | tar -xz -C "$TMPD/mtg"
MTG_SRC="$(find "$TMPD/mtg" -type f -name mtg -print -quit)"
[[ -n "$MTG_SRC" ]] || die "Бинарник mtg не найден в архиве"
systemctl stop mtg >/dev/null 2>&1 || true
install -m 755 "$MTG_SRC" /usr/local/bin/mtg

cat > /etc/mtg.toml <<EOF
secret = "${MTG_SECRET}"
bind-to = "127.0.0.1:${P_MTG}"
prefer-ip = "prefer-ipv4"
EOF
if [[ $CASCADE_OK == 1 ]]; then
  # mtg ходит к серверам Telegram через socks5 в Xray, а тот — через каскад за границу
  cat >> /etc/mtg.toml <<EOF

[network]
proxies = ["socks5://127.0.0.1:${P_CASCADE_SOCKS}"]
EOF
fi
chmod 644 /etc/mtg.toml
cat > /etc/systemd/system/mtg.service <<'EOF'
[Unit]
Description=mtg - MTProto proxy for Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run /etc/mtg.toml
Restart=always
RestartSec=3
DynamicUser=yes
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now mtg >/dev/null 2>&1
systemctl restart mtg
ok "mtg запущен"

# ----------------------------- nginx: этап 2 (TLS + stream) ------------------
log "Настраиваю nginx reverse proxy"
NGX_VER="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
if printf '%s\n' 1.25.1 "$NGX_VER" | sort -V -C; then H2_LISTEN=""; H2_ON="http2 on;"
else H2_LISTEN=" http2"; H2_ON=""; fi

cat > "/var/www/$DOMAIN/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Welcome</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:15vh auto;padding:0 16px;color:#333}</style>
</head><body><h1>Coming soon</h1><p>This site is under construction.</p></body></html>
EOF

cat > /etc/nginx/conf.d/20-site-tls.conf <<EOF
map \$http_upgrade \$xui_conn_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 127.0.0.1:${P_NGINX_TLS} ssl${H2_LISTEN} default_server;
    ${H2_ON}
    server_name ${DOMAIN};
    server_tokens off;

    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=63072000" always;

    root /var/www/${DOMAIN};
    index index.html;

    # Панель 3x-ui
    location = /${PANEL_PATH} { return 301 /${PANEL_PATH}/; }
    location /${PANEL_PATH}/ {
        proxy_pass ${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$xui_conn_upgrade;
    }

    # Подписки 3x-ui (обычные и JSON)
    location ^~ ${SUB_PATH} {
        proxy_pass ${SUB_SCHEME}://127.0.0.1:${SUB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
    location ^~ ${SUB_JSON_PATH} {
        proxy_pass ${SUB_SCHEME}://127.0.0.1:${SUB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    # VLESS + WebSocket
    location /${WS_PATH} {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:${P_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

L6_TCP=""; L6_UDP=""
if [[ $HAS_V6 == 1 ]]; then
  L6_TCP="listen [::]:443 reuseport;"
  L6_UDP="listen [::]:443 udp reuseport;"
fi
cat > /etc/nginx/stream.d/proxy.conf <<EOF
stream {
    map \$ssl_preread_server_name \$sni_backend {
        ${DOMAIN}       reality;
        ${MTG_DOMAIN}   mtproto;
        default         web;
    }

    upstream reality { server 127.0.0.1:${P_REALITY_TCP}; }
    upstream mtproto { server 127.0.0.1:${P_MTG}; }
    upstream web     { server 127.0.0.1:${P_NGINX_TLS}; }

    # 443/tcp: Reality, MTProto, сайт/панель/WS — по SNI
    server {
        listen 443 reuseport;
        ${L6_TCP}
        ssl_preread on;
        proxy_pass \$sni_backend;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;
    }

    # 443/udp: Hysteria2 (QUIC)
    server {
        listen 443 udp reuseport;
        ${L6_UDP}
        proxy_pass 127.0.0.1:${P_HY2};
        proxy_timeout 5m;
    }
}
EOF
grep -q 'stream.d/\*.conf' /etc/nginx/nginx.conf \
  || printf '\ninclude /etc/nginx/stream.d/*.conf;\n' >> /etc/nginx/nginx.conf

if ! nginx -t >/dev/null 2>&1; then
  nginx -t || true
  die "nginx не принял конфиг (нужен модуль stream: apt install libnginx-mod-stream)"
fi
systemctl restart nginx
ok "nginx настроен"

# ----------------------------- сеть и фаервол --------------------------------
log "Тюнинг сети (BBR, UDP-буферы для QUIC)"
cat > /etc/sysctl.d/99-proxy.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl --system >/dev/null 2>&1 || true

log "Настраиваю UFW: открываю 22, 80, 443 (уже существующие правила не трогаю)"
SSH_PORTS="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u || true)"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp  >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
for p in $SSH_PORTS; do
  if [[ "$p" != "22" ]]; then
    warn "sshd слушает порт $p — открываю его тоже, чтобы вы не потеряли доступ. Переведите SSH на 22 и удалите правило: ufw delete allow $p/tcp"
    ufw allow "$p/tcp" >/dev/null
  fi
done
ufw --force enable >/dev/null
ok "Фаервол включён"

# ----------------------------- проверка --------------------------------------
log "Проверяю, что всё слушает"
check() { ss -H -ln"$1" "sport = :$2" | grep -q . && ok "$3 (:$2/$( [[ $1 == t ]] && echo tcp || echo udp ))" || warn "$3 не слушает порт $2"; }
check t 443 "nginx stream"
check u 443 "nginx udp"
check t "$P_NGINX_TLS" "nginx TLS"
check t "$PANEL_PORT" "3x-ui панель"
check t "$SUB_PORT" "3x-ui подписки"
check t "$P_REALITY_TCP" "VLESS-TCP-Reality"
check t "$P_REALITY_XHTTP" "VLESS-XHTTP-Reality"
check t "$P_WS" "VLESS-WS"
check u "$P_HY2" "Hysteria2"
check t "$P_MTG" "MTProto"
if [[ $CASCADE_OK == 1 ]]; then check t "$P_CASCADE_SOCKS" "socks для MTProto → каскад"; fi
rm -rf "$TMPD"

# ----------------------------- итог ------------------------------------------
LINK_TCP="vless://${UUID_TCP}@${DOMAIN}:443?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${DOMAIN}&fp=chrome&pbk=${PUB_TCP}&sid=${SID_TCP}&spx=%2F#${DOMAIN}-TCP-Reality"
LINK_XHTTP="vless://${UUID_XHTTP}@${DOMAIN}:443?type=xhttp&security=reality&encryption=none&path=%2F${XHTTP_PATH}&mode=auto&sni=${DOMAIN}&fp=chrome&pbk=${PUB_XHTTP}&sid=${SID_XHTTP}&spx=%2F#${DOMAIN}-XHTTP-Reality"
LINK_WS="vless://${UUID_WS}@${DOMAIN}:443?type=ws&security=tls&encryption=none&path=%2F${WS_PATH}&host=${DOMAIN}&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1#${DOMAIN}-WS-TLS"
LINK_HY2="hysteria2://${HY2_AUTH}@${DOMAIN}:443?sni=${DOMAIN}&alpn=h3#${DOMAIN}-Hysteria2"
LINK_TG="https://t.me/proxy?server=${DOMAIN}&port=443&secret=${MTG_SECRET}"
LINK_SUB="https://${DOMAIN}${SUB_PATH}${SUB_ID}"
LINK_SUB_JSON="https://${DOMAIN}${SUB_JSON_PATH}${SUB_ID}"
SUB_CODE="$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' --resolve "${DOMAIN}:443:127.0.0.1" "$LINK_SUB" || true)"
if [[ "$SUB_CODE" == "200" ]]; then ok "Подписка отдаётся через nginx (HTTP 200)"
else warn "Подписка через nginx вернула HTTP ${SUB_CODE:-000} — проверьте: curl -v $LINK_SUB"; fi

# ----------------------------- самотест --------------------------------------
# Ставим proxy-selftest: поднимает локальный Xray-клиент по подписке и проверяет,
# что через каждый протокол реально ходит трафик. Пригодится и потом:
#   proxy-selftest                    — по ссылкам из /root/proxy-credentials.txt
#   proxy-selftest '<ссылка подписки>' — ровно то, что получает клиент
#   LOGLEVEL=debug proxy-selftest ... — с подробным логом причин ошибок
cat > /usr/local/bin/proxy-selftest <<'SELFTEST_EOF'
#!/usr/bin/env bash
# =============================================================================
#  proxy-selftest.sh — проверка всех конфигов прямо на сервере.
#  Поднимает локальный Xray-клиент по ссылкам из /root/proxy-credentials.txt,
#  подключается к своему же nginx (127.0.0.1:443, SNI = домен) и проверяет,
#  проходит ли через каждый протокол HTTP-запрос в интернет.
#
#  Если тут всё OK, а у клиента нет — проблема между вами и сервером
#  (провайдер/DPI/настройки клиента), а не в конфиге сервера.
#  С каскадом проверяется вся цепочка: этот сервер → зарубежный → интернет.
#
#  Использование:  bash proxy-selftest.sh [файл-со-ссылками]
#  Переменные:     CONNECT_ADDR (127.0.0.1), CONNECT_PORT (443),
#                  CA_FILE — доверять своему CA (для тестов с самоподписанным)
# =============================================================================
set -uo pipefail

LINKS_FILE="${1:-/root/proxy-credentials.txt}"
CONNECT_ADDR="${CONNECT_ADDR:-127.0.0.1}"
CONNECT_PORT="${CONNECT_PORT:-443}"
TEST_URL="${TEST_URL:-http://cp.cloudflare.com/generate_204}"
XRAY="${XRAY:-$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)}"
CA_FILE="${CA_FILE:-}"
LOGLEVEL="${LOGLEVEL:-warning}"   # debug — подробный лог клиента при ошибках

g=$'\e[32m'; r=$'\e[31m'; y=$'\e[33m'; n=$'\e[0m'
[[ -x "$XRAY" ]] || { echo "Не найден xray (задайте XRAY=путь)"; exit 1; }
command -v jq >/dev/null || { echo "Нужен jq: apt install jq"; exit 1; }

WORK="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

# Аргумент — ссылка подписки: скачиваем её через свой же nginx и тестируем
# ровно те конфиги, которые получает клиент.
if [[ "$LINKS_FILE" =~ ^https?://([^/:]+)(:([0-9]+))? ]]; then
  SUB_HOST="${BASH_REMATCH[1]}"; SUB_PORT="${BASH_REMATCH[3]:-443}"
  body="$(env -u no_proxy -u NO_PROXY curl -sk -m 10 --noproxy '*' --resolve "${SUB_HOST}:${SUB_PORT}:127.0.0.1" "$LINKS_FILE" || true)"
  [[ -n "$body" ]] || { echo "Подписка $LINKS_FILE не скачалась"; exit 1; }
  if grep -qE '^(vless|hysteria2|hy2)://' <<<"$body"; then printf '%s\n' "$body" > "$WORK/sub.txt"
  else base64 -d <<<"$body" > "$WORK/sub.txt" 2>/dev/null || { echo "Не смог декодировать подписку"; exit 1; }; fi
  echo "Подписка: $LINKS_FILE"
  LINKS_FILE="$WORK/sub.txt"
fi
[[ -f "$LINKS_FILE" ]] || { echo "Нет файла $LINKS_FILE"; exit 1; }

# разбор ссылок и тест outbound — общий код с deploy-proxy.sh
. /usr/local/lib/proxy-links.sh 2>/dev/null \
  || { echo "Нет /usr/local/lib/proxy-links.sh — перезапустите deploy-proxy.sh"; exit 1; }

echo "Xray: $("$XRAY" version | head -n1)"
echo "Подключаюсь к ${CONNECT_ADDR}:${CONNECT_PORT}, проверяю ${TEST_URL}"
echo

i=0; fails=0
while IFS= read -r link; do
  [[ "$link" =~ ^(vless|hysteria2|hy2):// ]] || continue
  i=$((i+1))
  name="$(urldecode "${link##*#}")"
  ob="$(build_outbound "$link" "$CONNECT_ADDR" "$CONNECT_PORT" 2>/dev/null)" || ob=""
  if [[ -z "$ob" ]]; then echo "${y}[skip]${n} $name — не разобрал ссылку"; continue; fi
  if test_outbound "$ob" $((20800 + i)) "$WORK/c$i.log"; then
    echo "${g}[ OK ]${n} $name"
  else
    fails=$((fails+1))
    echo "${r}[FAIL]${n} $name (HTTP ${TEST_CODE})"
    xray_log_tail "$WORK/c$i.log" "$([[ $LOGLEVEL == debug ]] && echo 15 || echo 4)"
  fi
done < "$LINKS_FILE"

[[ $i -gt 0 ]] || { echo "В $LINKS_FILE не найдено ссылок vless:// или hysteria2://"; exit 1; }
echo
if [[ $fails -gt 0 && -r /var/log/nginx/error.log ]]; then
  echo "--- последние ошибки nginx ---"; tail -n 8 /var/log/nginx/error.log
fi
echo "Итого: $((i-fails))/$i работают на стороне сервера."
[[ $fails -eq 0 ]]
SELFTEST_EOF
chmod 755 /usr/local/bin/proxy-selftest

case "$CERT_HOW" in
  file)       CERT_RENEW="НЕТ (свой сертификат) — замените файлы в ${SSL_DIR} до истечения" ;;
  manual-dns) CERT_RENEW="ВРУЧНУЮ раз в ~2 месяца: proxy-cert-renew (попросит обновить TXT-запись)" ;;
  *)          CERT_RENEW="автоматически (acme.sh по cron, CA: ${ISSUED_BY}); принудительно: proxy-cert-renew" ;;
esac

if [[ $CASCADE_OK == 1 ]]; then
  CASCADE_INFO="через ${CASCADE_HOST}:${CASCADE_PORT} (${CASCADE_PROTO}), Telegram тоже; российские сайты: $([[ $CASCADE_RU_DIRECT == 1 ]] && echo 'напрямую' || echo 'через каскад')"
elif [[ -n "$CASCADE_OB" ]]; then
  CASCADE_INFO="ЗАПРОШЕН, НО НЕ ВКЛЮЧЁН — трафик идёт напрямую с этого сервера"
else
  CASCADE_INFO="нет, выход в интернет прямо с этого сервера"
fi

umask 077
cat > "$INFO_FILE" <<EOF
================= ${DOMAIN} — $(date '+%Y-%m-%d %H:%M') =================

Панель 3x-ui:   https://${DOMAIN}/${PANEL_PATH}/
Логин:          ${PANEL_USER}
Пароль:         ${PANEL_PASS}

Сертификат:     ${CERT_ISSUER}
Действует до:   ${CERT_END}
Продление:      ${CERT_RENEW}
Файлы:          ${CERT}, ${KEY}

Каскад:         ${CASCADE_INFO}

--- VLESS + TCP + Reality (Vision) ---
${LINK_TCP}

--- VLESS + XHTTP + Reality ---
${LINK_XHTTP}

--- VLESS + WebSocket + TLS (через nginx) ---
${LINK_WS}

--- Hysteria2 (UDP 443) ---
${LINK_HY2}

--- Telegram (MTProto, Fake-TLS) ---
${LINK_TG}

=== ПОДПИСКА (все 4 конфига одной ссылкой — вставить в клиент) ===
${LINK_SUB}
JSON-подписка (для клиентов на чистом Xray): ${LINK_SUB_JSON}

Reality public keys:  TCP=${PUB_TCP}  XHTTP=${PUB_XHTTP}
JSON инбаундов (для ручного импорта в панели): ${INBOUNDS_DIR}/

--- Важно при ручных изменениях в панели ---
* Новый клиент на ВСЕ инбаунды: Flow оставляйте ПУСТЫМ. xtls-rprx-vision нужен
  только на VLESS-TCP-Reality — на XHTTP/WS с ним Xray отвергает подключения.
* Не включайте SSL у панели/подписок (x-ui → SSL): TLS держит nginx.
  Если всё же включили — перезапустите этот скрипт или поменяйте в
  /etc/nginx/conf.d/20-site-tls.conf proxy_pass http:// на https://.
* Проверка всех протоколов в любой момент:  proxy-selftest '${LINK_SUB}'
  (с каскадом проверяется вся цепочка: этот сервер → зарубежный → интернет)
* Каскад живёт в панели: Xray Configs → outbound "cascade" (первый = по умолчанию)
  и inbound "mtg-in" для Telegram. Не удаляйте их, если каскад нужен.
EOF

echo
cat "$INFO_FILE"
echo
if [[ $API_OK != 1 ]]; then
  warn "Часть инбаундов не добавилась через API. Откройте панель → Inbounds → Import"
  warn "и вставьте содержимое файлов из ${INBOUNDS_DIR}/ (ссылки выше останутся рабочими)."
fi
if [[ $API_OK == 1 ]]; then
  log "Самотест: проверяю все протоколы по подписке"
  sleep 2
  if proxy-selftest "$LINK_SUB"; then ok "Самотест пройден"
  else warn "Самотест нашёл проблемы (см. выше). Подробнее: LOGLEVEL=debug proxy-selftest '$LINK_SUB'"; fi
fi

echo
log "Подписка для приложения (Hiddify, v2rayNG, v2RayTun, Happ, Streisand): отсканируйте QR или скопируйте ссылку"
if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 -m 1 "$LINK_SUB" || true; fi
echo "  ${LINK_SUB}"
echo
log "Прокси для Telegram: откройте ссылку на устройстве с Telegram"
echo "  ${LINK_TG}"
echo
if [[ -n "$CASCADE_OB" ]]; then
  if [[ $CASCADE_OK == 1 ]]; then ok "Каскад: ${CASCADE_INFO}"
  else warn "Каскад: ${CASCADE_INFO}"; fi
fi
if [[ "$CERT_HOW" == manual-dns ]]; then
  warn "Сертификат продлевается ВРУЧНУЮ: раз в ~2 месяца запустите  proxy-cert-renew"
fi
ok "Готово. Все данные (панель, пароли, ссылки): cat ${INFO_FILE}"
