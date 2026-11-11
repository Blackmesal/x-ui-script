#!/usr/bin/env bash
# =============================================================================
#  uninstall-proxy.sh — удаление всего, что поставил deploy-proxy.sh:
#    3x-ui (панель, Xray, база, бэкапы базы), MTProto (mtg), конфиги nginx,
#    сайт-заглушка, TLS-сертификат и acme.sh, proxy-selftest, proxy-cert-renew,
#    предупреждение в motd, тюнинг сети, /root/proxy-credentials.txt.
#
#  Запуск от root:  bash uninstall-proxy.sh
#  Скрипт покажет, что нашёл, спросит подтверждение и ещё два вопроса:
#  удалять ли nginx целиком и закрывать ли порты 80/443 в фаерволе.
#
#  Без вопросов (необязательно):
#    FORCE=1          — не спрашивать подтверждение
#    PURGE_NGINX=0|1  — удалить пакет nginx целиком (1) или только наши конфиги (0)
#    CLOSE_PORTS=0|1  — убрать правила UFW для 80/tcp, 443/tcp, 443/udp
#
#  НЕ трогает: SSH и его правила в UFW, сам UFW (остаётся включённым),
#  общие пакеты (curl, jq, sqlite3, qrencode, cron и т.п.).
# =============================================================================
set -uo pipefail
shopt -s nullglob

# ----------------------------- пути (как в deploy-proxy.sh) ------------------
XUI_DIR=/usr/local/x-ui
XUI_ETC=/etc/x-ui
INBOUNDS_DIR=/root/3x-ui-inbounds
INFO_FILE=/root/proxy-credentials.txt
SSL_ROOT=/etc/ssl/proxy
ACME_HOME=/root/.acme.sh
ACME="$ACME_HOME/acme.sh"
ACME_WEBROOT=/var/www/acme
NGX_FILES=(/etc/nginx/conf.d/10-http80.conf /etc/nginx/conf.d/20-site-tls.conf /etc/nginx/stream.d/proxy.conf)
OUR_FILES=(
  /usr/local/bin/proxy-cert-renew
  /usr/local/bin/proxy-selftest
  /usr/local/lib/proxy-links.sh
  /etc/update-motd.d/99-proxy-cert
  /etc/sysctl.d/99-proxy.conf
  /usr/local/bin/mtg
  /etc/mtg.toml
  "$INFO_FILE"
)

# ----------------------------- утилиты ---------------------------------------
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_rst=$'\e[0m'
log()  { echo "${c_cyn}==>${c_rst} $*"; }
ok()   { echo "${c_grn}[ok]${c_rst} $*"; }
warn() { echo "${c_ylw}[!]${c_rst} $*" >&2; }
die()  { echo "${c_red}[x]${c_rst} $*" >&2; exit 1; }

# Вопросы через /dev/tty: работает и `bash uninstall-proxy.sh`, и `curl ... | bash`
TTY=""; (exec </dev/tty) 2>/dev/null && TTY=/dev/tty
ask() {
  [[ -n "$TTY" ]] || return 1
  local v; read -rp "$1" v <"$TTY" || return 1
  printf '%s' "$v"
}
yes_no() {  # вопрос, ответ по умолчанию (y|n) -> 0 = да
  local a
  a="$(ask "$1")" || a=""
  [[ -z "$a" ]] && a="$2"
  case "$a" in y|Y|yes|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
}

[[ $EUID -eq 0 ]] || die "Запустите от root:  sudo bash uninstall-proxy.sh"

# ----------------------------- что установлено -------------------------------
DOMAINS=()
for d in "$SSL_ROOT"/*/; do DOMAINS+=("$(basename "$d")"); done

FOUND=()
[[ -d "$XUI_DIR" || -f /etc/systemd/system/x-ui.service || -d "$XUI_ETC" ]] && FOUND+=("3x-ui (панель, Xray, база)")
[[ -f /usr/local/bin/mtg || -f /etc/systemd/system/mtg.service ]]           && FOUND+=("mtg (MTProto для Telegram)")
for f in "${NGX_FILES[@]}"; do [[ -f "$f" ]] && { FOUND+=("конфиги nginx"); break; }; done
[[ ${#DOMAINS[@]} -gt 0 ]] && FOUND+=("сертификат: ${DOMAINS[*]}")
[[ -x "$ACME" ]]           && FOUND+=("acme.sh")
for f in "${OUR_FILES[@]}"; do [[ -e "$f" ]] && { FOUND+=("служебные файлы (proxy-selftest, proxy-cert-renew, пароли…)"); break; }; done
[[ -d "$INBOUNDS_DIR" ]]   && FOUND+=("$INBOUNDS_DIR")

if [[ ${#FOUND[@]} -eq 0 ]]; then
  ok "Ничего от deploy-proxy.sh не найдено — удалять нечего."
  exit 0
fi

echo
log "Найдено:"
for x in "${FOUND[@]}"; do echo "    - $x"; done
echo

# ----------------------------- вопросы ---------------------------------------
if [[ "${FORCE:-0}" != 1 ]]; then
  warn "Всё перечисленное будет удалено. У всех клиентов перестанут работать конфиги и подписка,"
  warn "пароли панели и ссылки ($INFO_FILE) тоже удалятся."
  [[ -n "$TTY" ]] || die "Нет терминала для подтверждения. Запустите с FORCE=1"
  yes_no "Удалить? [y/N]: " n || { echo "Ничего не удалено."; exit 0; }
fi

# чужие сайты в nginx (кроме наших конфигов и стандартного default)
OTHER_NGX=()
for f in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/* /etc/nginx/stream.d/*.conf; do
  case "$f" in
    /etc/nginx/conf.d/10-http80.conf|/etc/nginx/conf.d/20-site-tls.conf|/etc/nginx/stream.d/proxy.conf) ;;
    /etc/nginx/sites-enabled/default) ;;
    *) OTHER_NGX+=("$f") ;;
  esac
done

PURGE_NGINX="${PURGE_NGINX:-}"
if [[ -z "$PURGE_NGINX" ]] && command -v nginx >/dev/null 2>&1; then
  if [[ ${#OTHER_NGX[@]} -gt 0 ]]; then
    warn "В nginx есть и другие конфиги: ${OTHER_NGX[*]}"
    yes_no "Удалить nginx целиком (вместе с ними)? [y/N]: " n && PURGE_NGINX=1 || PURGE_NGINX=0
  else
    yes_no "Удалить nginx целиком (его поставил deploy-proxy.sh)? [Y/n]: " y && PURGE_NGINX=1 || PURGE_NGINX=0
  fi
fi
[[ "$PURGE_NGINX" == 1 ]] || PURGE_NGINX=0

CLOSE_PORTS="${CLOSE_PORTS:-}"
if [[ -z "$CLOSE_PORTS" ]] && command -v ufw >/dev/null 2>&1; then
  if [[ $PURGE_NGINX == 1 ]]; then
    yes_no "Закрыть в фаерволе порты 80 и 443 (SSH не трогаю)? [Y/n]: " y && CLOSE_PORTS=1 || CLOSE_PORTS=0
  else
    yes_no "Закрыть в фаерволе порты 80 и 443 (SSH не трогаю)? [y/N]: " n && CLOSE_PORTS=1 || CLOSE_PORTS=0
  fi
fi
[[ "$CLOSE_PORTS" == 1 ]] || CLOSE_PORTS=0

# ----------------------------- службы ----------------------------------------
log "Останавливаю службы"
for s in x-ui mtg; do
  systemctl disable --now "$s" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$s.service"
done
pkill -f "$XUI_DIR/bin/xray" >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed >/dev/null 2>&1 || true
ok "x-ui и mtg остановлены"

# ----------------------------- 3x-ui и mtg -----------------------------------
log "Удаляю 3x-ui и mtg"
rm -rf "$XUI_DIR" "$XUI_ETC" /var/log/x-ui "$INBOUNDS_DIR"
# /usr/bin/x-ui — управляющий скрипт 3x-ui; удаляем, только если это он
if [[ -f /usr/bin/x-ui ]] && grep -qi '3x-ui\|x-ui' /usr/bin/x-ui 2>/dev/null; then rm -f /usr/bin/x-ui; fi
rm -f /usr/local/bin/mtg /etc/mtg.toml
ok "3x-ui и mtg удалены"

# ----------------------------- nginx -----------------------------------------
if command -v nginx >/dev/null 2>&1 || [[ -d /etc/nginx ]]; then
  log "Убираю настройки nginx"
  rm -f "${NGX_FILES[@]}"
  rmdir /etc/nginx/stream.d 2>/dev/null || true
  [[ -f /etc/nginx/nginx.conf ]] && sed -i '\#^include /etc/nginx/stream\.d/\*\.conf;$#d' /etc/nginx/nginx.conf

  if [[ $PURGE_NGINX == 1 ]]; then
    systemctl disable --now nginx >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y 'nginx*' 'libnginx-mod-*' >/dev/null 2>&1 \
      || warn "apt не смог удалить nginx — удалите вручную: apt purge nginx nginx-common"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
    rm -rf /etc/nginx
    ok "nginx удалён"
  else
    # deploy-proxy.sh выключал стандартный сайт — возвращаем, если других сайтов нет
    if [[ ${#OTHER_NGX[@]} -eq 0 && -f /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]]; then
      ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    fi
    if nginx -t >/dev/null 2>&1; then
      systemctl restart nginx >/dev/null 2>&1 || true
      ok "nginx оставлен, наши конфиги убраны"
    else
      nginx -t || true
      warn "nginx не принимает оставшийся конфиг — поправьте вручную (наши файлы уже удалены)"
    fi
  fi
fi
# сайт-заглушка и каталог для ACME-проверки
rm -rf "$ACME_WEBROOT"
for d in "${DOMAINS[@]}"; do rm -rf "/var/www/$d"; done

# ----------------------------- сертификат и acme.sh --------------------------
log "Удаляю сертификат"
if [[ -x "$ACME" ]]; then
  for d in "${DOMAINS[@]}"; do
    "$ACME" --remove -d "$d" --ecc >/dev/null 2>&1 || true
    rm -rf "$ACME_HOME/${d}_ecc" "$ACME_HOME/$d"
  done
  # остались ли в acme.sh чужие сертификаты (первая строка --list — заголовок)
  left="$("$ACME" --list 2>/dev/null | tail -n +2 | grep -c . || true)"
  if [[ "${left:-0}" -eq 0 ]]; then
    "$ACME" --uninstall --home "$ACME_HOME" >/dev/null 2>&1 || true
    rm -rf "$ACME_HOME"
    ok "acme.sh удалён"
  else
    rm -f "$ACME_HOME/dnsapi/dns_tty.sh"
    warn "В acme.sh есть другие сертификаты ($left шт.) — сам acme.sh оставлен"
  fi
fi
# страховка: строка acme.sh в cron и в .bashrc
if crontab -l >/dev/null 2>&1 && ! [[ -d "$ACME_HOME" ]]; then
  crontab -l 2>/dev/null | grep -vF "$ACME_HOME" | crontab - 2>/dev/null || true
fi
[[ -d "$ACME_HOME" ]] || sed -i '\#\.acme\.sh/acme\.sh\.env#d' /root/.bashrc 2>/dev/null || true
rm -rf "$SSL_ROOT"
ok "Сертификат удалён"

# ----------------------------- служебные файлы и сеть ------------------------
log "Удаляю служебные файлы"
rm -f "${OUR_FILES[@]}"
sysctl --system >/dev/null 2>&1 || true
ok "proxy-selftest, proxy-cert-renew, motd, пароли и тюнинг сети удалены"

# ----------------------------- фаервол ---------------------------------------
if [[ $CLOSE_PORTS == 1 ]] && command -v ufw >/dev/null 2>&1; then
  log "Закрываю 80 и 443 в UFW"
  for r in 80/tcp 443/tcp 443/udp; do ufw --force delete allow "$r" >/dev/null 2>&1 || true; done
  ok "Порты 80 и 443 закрыты (SSH открыт, UFW включён)"
fi

# ----------------------------- проверка --------------------------------------
log "Проверяю, что ничего не осталось"
busy=()
for p in 2053 2096 8443 10001 10002 10003 10005 10006; do
  ss -H -lnt "sport = :$p" 2>/dev/null | grep -q . && busy+=("$p/tcp")
done
ss -H -lnu "sport = :10004" 2>/dev/null | grep -q . && busy+=("10004/udp")
if [[ ${#busy[@]} -gt 0 ]]; then
  warn "Порты всё ещё заняты: ${busy[*]} — посмотрите: ss -lntup"
else
  ok "Порты панели, Xray и mtg свободны"
fi

echo
ok "Готово. Панель и всё, что ставил deploy-proxy.sh, удалено."
echo "    Тюнинг сети (BBR, буферы) окончательно сбросится после перезагрузки."
echo "    Общие пакеты (curl, jq, sqlite3, qrencode, ufw, cron) оставлены."
