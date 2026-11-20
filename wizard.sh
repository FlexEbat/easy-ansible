#!/usr/bin/env bash
#
# Interactive generator for vars.local.yml.
#
# Normally started by run.sh when vars.local.yml does not exist yet. It can
# also be used on its own, for example on a laptop before a remote run:
#   ./wizard.sh            # or: ./run.sh --wizard-only
#
# The answers are written to vars.local.yml (override with VARS_FILE=...).

set -euo pipefail
cd "$(dirname "$0")"

OUT="${VARS_FILE:-vars.local.yml}"

# --- helpers ----------------------------------------------------------------
# ask PROMPT [DEFAULT]  -> REPLY
ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " reply
  else
    read -r -p "$prompt: " reply
  fi
  REPLY="${reply:-$default}"
}

# yesno PROMPT y|n  -> exit status 0 for yes
yesno() {
  local prompt="$1" default="$2" reply hint
  if [ "$default" = "y" ]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    read -r -p "$prompt [$hint]: " reply
    reply="${reply:-$default}"
    case "${reply,,}" in
      y | yes | д | да) return 0 ;;
      n | no | н | нет) return 1 ;;
    esac
    echo "  Ответьте y (да) или n (нет)."
  done
}

# Private IPv4 network of the default route (e.g. 192.168.1.0/24), if any.
detect_lan() {
  command -v ip >/dev/null 2>&1 || return 0
  local dev addr
  dev=$(ip -4 route show default 2>/dev/null |
    awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [ -n "$dev" ] || return 0
  addr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4; exit}')
  [ -n "$addr" ] || return 0
  python3 - "$addr" 2>/dev/null <<'PY' || true
import ipaddress
import sys

net = ipaddress.ip_interface(sys.argv[1]).network
if net.is_private:
    print(net)
PY
}

# IP address of the terminal this script was started from (SSH client), if any.
detect_client_ip() {
  local ip
  ip=$(who am i 2>/dev/null | sed -n 's/.*(\(.*\))$/\1/p')
  [ -n "$ip" ] || return 0
  python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1]); print(sys.argv[1])' \
    "$ip" 2>/dev/null || true
}

valid_cidr() {
  python3 -c 'import ipaddress, sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$1" 2>/dev/null
}

valid_ip() {
  python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$1" 2>/dev/null
}

# --- start ------------------------------------------------------------------
echo "== Мастер настройки easy-ansible =="
echo "Ответы будут сохранены в $OUT. Enter — принять значение в скобках."
echo

if [ -e "$OUT" ]; then
  if ! yesno "$OUT уже существует. Перезаписать (старый сохраню как $OUT.bak)?" n; then
    echo "Оставляю $OUT без изменений."
    exit 0
  fi
  cp -f "$OUT" "$OUT.bak"
fi

echo "Что настраиваем?"
echo "  1) домашний компьютер / домашний сервер"
echo "  2) сервер (VPS, доступен из интернета)"
while true; do
  ask "Выбор" 1
  case "$REPLY" in
    1) KIND=home; break ;;
    2) KIND=server; break ;;
    *) echo "  Введите 1 или 2." ;;
  esac
done

# --- administrator account ----------------------------------------------------
DEFAULT_USER="${SUDO_USER:-}"
if [ -z "$DEFAULT_USER" ] || [ "$DEFAULT_USER" = "root" ]; then
  DEFAULT_USER=$(id -un)
fi
if [ "$DEFAULT_USER" = "root" ]; then
  DEFAULT_USER="admin"
fi

generate_username() {
  python3 -c 'import secrets, string; print("adm-" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(6)))'
}

echo
echo "Пользователь-администратор получит sudo. Введите имя, либо auto — сгенерировать случайное."
while true; do
  ask "Пользователь-администратор (если его нет, он будет создан)" "$DEFAULT_USER"
  ADMIN="$REPLY"
  if [ "$ADMIN" = "auto" ]; then
    ADMIN=$(generate_username)
    echo "  Сгенерировано имя: $ADMIN (запишите его, оно будет показано в конце)."
  fi
  if [[ "$ADMIN" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    break
  fi
  echo "  Допустимы строчные латинские буквы, цифры, '_' и '-'."
done

USER_EXISTS=0
if getent passwd "$ADMIN" >/dev/null 2>&1; then
  USER_EXISTS=1
fi

KEY=""
HASH=""
NOPASSWD=""
if [ "$KIND" = "server" ] || [ "$USER_EXISTS" -eq 0 ]; then
  echo
  echo "Вход по SSH-ключу. Вставьте публичный ключ (ssh-ed25519 AAAA...) или путь к"
  echo "файлу .pub (например, ~/.ssh/id_ed25519.pub). Enter — пропустить."
  while true; do
    read -r -p "Ключ для $ADMIN: " REPLY
    REPLY="${REPLY/#\~/$HOME}"
    if [ -f "$REPLY" ]; then
      REPLY=$(head -n 1 "$REPLY")
    fi
    if [ -z "$REPLY" ]; then
      break
    fi
    if [[ "$REPLY" =~ ^(ssh-|ecdsa-|sk-)[^[:space:]]+[[:space:]]+[^[:space:]]+ ]]; then
      KEY="$REPLY"
      break
    fi
    echo "  Это не похоже на публичный SSH-ключ. Повторите или нажмите Enter."
  done

  if [ -n "$KEY" ] && [ "$USER_EXISTS" -eq 0 ]; then
    NOPASSWD=true
    echo "  Новый пользователь будет входить по ключу без пароля, поэтому sudo без пароля включу."
  elif [ -n "$KEY" ]; then
    if yesno "Включить sudo без пароля для $ADMIN?" n; then
      NOPASSWD=true
    fi
  fi

  if [ -z "$KEY" ] && [ "$USER_EXISTS" -eq 0 ]; then
    echo
    echo "Ключа нет, а нового пользователя иначе не залогинить. Задайте ему пароль"
    echo "(Enter — пропустить; тогда учётка останется заблокированной)."
    if command -v openssl >/dev/null 2>&1; then
      while true; do
        read -r -s -p "Пароль для $ADMIN: " PW1
        echo
        if [ -z "$PW1" ]; then
          break
        fi
        read -r -s -p "Повторите пароль: " PW2
        echo
        if [ "$PW1" != "$PW2" ]; then
          echo "  Пароли не совпадают."
        elif [ "${#PW1}" -lt 8 ]; then
          echo "  Минимум 8 символов."
        else
          HASH=$(printf '%s' "$PW1" | openssl passwd -6 -stdin)
          break
        fi
      done
    else
      echo "  openssl не найден: пароль не задать. Добавьте ключ в $OUT позже."
    fi
    if [ -z "$HASH" ]; then
      echo "  ВНИМАНИЕ: пользователь $ADMIN будет создан заблокированным."
    fi
  fi
fi

# --- addresses that CrowdSec must never ban -------------------------------------
LAN=$(detect_lan)
CLIENT_IP=$(detect_client_ip)

echo
echo "CrowdSec банит адреса за перебор паролей. Чтобы не заблокировать себя,"
echo "укажите свои адреса (через пробел; Enter — пропустить)."
while true; do
  ask "Ваши IP-адреса" "$CLIENT_IP"
  IPS="$REPLY"
  ok=1
  for item in $IPS; do
    valid_ip "$item" || { echo "  Неверный IP: $item"; ok=0; }
  done
  [ "$ok" -eq 1 ] && break
done

LAN_DEFAULT=""
if [ "$KIND" = "home" ]; then
  LAN_DEFAULT="$LAN"
fi
while true; do
  ask "Ваши подсети (CIDR, например 192.168.1.0/24)" "$LAN_DEFAULT"
  CIDRS="$REPLY"
  ok=1
  for item in $CIDRS; do
    valid_cidr "$item" || { echo "  Неверная подсеть: $item"; ok=0; }
  done
  [ "$ok" -eq 1 ] && break
done

# --- firewall ports ---------------------------------------------------------------
echo
echo "Firewall закрывает все входящие подключения, кроме SSH (22/tcp)."
echo "Какие порты открыть? Через пробел, например: 80 443 51820/udp (Enter — никакие)."
while true; do
  read -r -p "Порты: " PORTS
  ok=1
  for item in $PORTS; do
    if [[ "$item" =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]] &&
      [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[1]}" -le 65535 ]; then
      :
    else
      echo "  Неверный порт: $item"
      ok=0
    fi
  done
  [ "$ok" -eq 1 ] && break
done

PORTS_FROM=""
if [ -n "$PORTS" ] && [ -n "$LAN" ] && [ "$KIND" = "home" ]; then
  if yesno "Открыть эти порты только для локальной сети $LAN?" y; then
    PORTS_FROM="$LAN"
  fi
fi

# --- other options --------------------------------------------------------------------
echo
if [ "$KIND" = "server" ]; then
  IPV6_DEFAULT=y
else
  IPV6_DEFAULT=n
fi
IPV6_OFF=0
if yesno "Отключить IPv6?" "$IPV6_DEFAULT"; then
  IPV6_OFF=1
fi

DOCKER_LOCAL=0
if yesno "Публиковать порты Docker только на localhost (Docker обходит firewall)?" y; then
  DOCKER_LOCAL=1
fi

# --- SSH ---------------------------------------------------------------------------
SSH_PORT=22
SSH_HARDEN=0
SSH_EXTRA=0
SSH_CRYPTO=0
echo
if yesno "Сменить порт SSH (по умолчанию 22)? Порт будет открыт в firewall автоматически" n; then
  while true; do
    ask "Новый порт SSH (1-65535)" 2222
    if [[ "$REPLY" =~ ^[0-9]{1,5}$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le 65535 ]; then
      SSH_PORT="$REPLY"
      break
    fi
    echo "  Неверный порт."
  done
  echo "  Откройте $SSH_PORT/tcp и в firewall хостера; старое правило для порта 22 останется,"
  echo "  пока вы не включите firewall_close_old_ssh_port (см. README)."
fi
if [ -n "$KEY" ]; then
  if yesno "Запретить вход по паролю и вход root (только по ключу)?" y; then
    SSH_HARDEN=1
  fi
else
  echo "  Ключ не задан: вход по паролю останется (иначе вы потеряете доступ)."
fi
if yesno "Дополнительные настройки sshd (таймауты, лимиты; туннели и прокси продолжают работать)?" n; then
  SSH_EXTRA=1
fi
if yesno "Только современные алгоритмы шифрования SSH (очень старые клиенты не подключатся)?" n; then
  SSH_CRYPTO=1
fi

# --- optional hardening: every item is off unless you say yes -----------------------
HARDEN_LIST=""
DOCKER_PRUNE=0
echo
echo "Дополнительная защита. Всё необязательно и отключается обратно (см. раздел «Откат» в README)."
if yesno "Включить рекомендуемый набор (sysctl, sudo, пароли, без core dump, чёрный список модулей, баннер, MAC)?" n; then
  HARDEN_LIST="harden_sysctl harden_sudo harden_password_policy harden_coredumps harden_kernel_modules harden_banner harden_mac"
fi
for item in \
  "harden_sysctl|дополнительные sysctl (kptr_restrict, ptrace_scope, protected_*)" \
  "harden_sudo|sudo: use_pty, отдельный лог, таймаут пароля 5 минут" \
  "harden_password_policy|политика паролей (минимум 12 символов, 3 класса)" \
  "harden_coredumps|запретить создание core dump" \
  "harden_kernel_modules|чёрный список редких модулей ядра (dccp, sctp, rds, tipc, cramfs...)" \
  "harden_banner|предупреждающий баннер при входе" \
  "harden_cron_at|cron/at только для root и администратора" \
  "harden_mac|AppArmor (Debian/Ubuntu) / SELinux (RHEL): включить и обновить" \
  "harden_auditd|auditd с набором правил" \
  "harden_lynis|установить Lynis (аудит: sudo lynis audit system)"; do
  var="${item%%|*}"
  case " $HARDEN_LIST " in *" $var "*) continue ;; esac
  if yesno "  $var: ${item#*|}?" n; then
    HARDEN_LIST="$HARDEN_LIST $var"
  fi
done
if yesno "Раз в неделю чистить неиспользуемые данные Docker (volumes не трогаются)?" n; then
  DOCKER_PRUNE=1
fi

# --- write the file ---------------------------------------------------------------------
export WZ_OUT="$OUT" WZ_ADMIN="$ADMIN" WZ_KEY="$KEY" WZ_HASH="$HASH" WZ_NOPASSWD="$NOPASSWD"
export WZ_IPS="$IPS" WZ_CIDRS="$CIDRS" WZ_PORTS="$PORTS" WZ_PORTS_FROM="$PORTS_FROM"
export WZ_IPV6_OFF="$IPV6_OFF" WZ_DOCKER_LOCAL="$DOCKER_LOCAL"
export WZ_SSH_PORT="$SSH_PORT" WZ_SSH_HARDEN="$SSH_HARDEN" WZ_SSH_EXTRA="$SSH_EXTRA" WZ_SSH_CRYPTO="$SSH_CRYPTO"
export WZ_HARDEN="$HARDEN_LIST" WZ_DOCKER_PRUNE="$DOCKER_PRUNE"

python3 - <<'PY'
import datetime
import json
import os

env = os.environ


def j(value):
    return json.dumps(value, ensure_ascii=False)


lines = [
    "---",
    "# Создано wizard.sh (%s). Можно править вручную;" % datetime.date.today(),
    "# все доступные переменные — в vars.example.yml и README.",
    "admin_user: %s" % j(env["WZ_ADMIN"]),
]
if env["WZ_KEY"]:
    lines += ["admin_user_authorized_keys:", "  - %s" % j(env["WZ_KEY"])]
if env["WZ_HASH"]:
    lines.append("admin_user_password_hash: %s" % j(env["WZ_HASH"]))
if env["WZ_NOPASSWD"] == "true":
    lines.append("admin_user_sudo_nopasswd: true")

lines.append("crowdsec_whitelist_ips: %s" % j(env["WZ_IPS"].split()))
lines.append("crowdsec_whitelist_cidrs: %s" % j(env["WZ_CIDRS"].split()))

ports = env["WZ_PORTS"].split()
if ports:
    lines.append("firewall_allowed_ports:")
    for item in ports:
        number, _, proto = item.partition("/")
        entry = {"port": int(number), "proto": proto or "tcp"}
        if env["WZ_PORTS_FROM"]:
            entry["from"] = env["WZ_PORTS_FROM"]
        lines.append("  - %s" % j(entry))
else:
    lines.append("firewall_allowed_ports: []")

lines.append("disable_ipv6: %s" % ("true" if env["WZ_IPV6_OFF"] == "1" else "false"))
if env["WZ_DOCKER_LOCAL"] == "1":
    lines.append('docker_default_bind_ip: "127.0.0.1"')
if env["WZ_SSH_PORT"] != "22":
    lines.append("ssh_port: %s" % env["WZ_SSH_PORT"])
if env["WZ_SSH_HARDEN"] == "1":
    lines += ["ssh_harden: true", "ssh_password_auth: false", 'ssh_permit_root_login: "no"']
if env["WZ_SSH_EXTRA"] == "1":
    lines.append("ssh_harden_extra: true")
if env["WZ_SSH_CRYPTO"] == "1":
    lines.append("ssh_modern_crypto: true")
for name in env["WZ_HARDEN"].split():
    lines.append("%s: true" % name)
if env["WZ_DOCKER_PRUNE"] == "1":
    lines.append("docker_prune_enabled: true")
# Automatic updates (unattended-upgrades / dnf-automatic) stay on; automatic reboots stay off.
lines += ["auto_updates_enabled: true", "auto_reboot: false"]

with open(env["WZ_OUT"], "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY

chmod 600 "$OUT"
# Under sudo the file would otherwise belong to root and be awkward to edit.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$OUT" 2>/dev/null || true
fi

echo
echo "== Готово: $OUT =="
echo "Администратор: $ADMIN$([ "$USER_EXISTS" -eq 0 ] && echo ' (будет создан, с sudo)' || echo ' (sudo проверяется)')"
if [ "$SSH_PORT" != "22" ]; then
  echo "Порт SSH: $SSH_PORT  ->  ssh -p $SSH_PORT $ADMIN@<сервер>"
fi
sed -E 's/^(admin_user_password_hash: ).*/\1"<скрыто>"/' "$OUT"
echo
