#!/usr/bin/env bash
#
# Bootstrap Ansible on a fresh Debian/Ubuntu or RHEL-family machine and run the
# playbook with your settings.
#
# Settings live in vars.local.yml:
#   * the file exists          -> it is simply read;
#   * it does not exist        -> a short questionnaire (wizard.sh) creates it.
#
# Usage:
#   ./run.sh                 # asks for sudo if needed; uses or creates vars.local.yml
#   ./run.sh --wizard        # ask the questions again (old file is saved as .bak)
#   ./run.sh --wizard-only   # only create vars.local.yml (e.g. for a remote run), no root needed
#   ./run.sh --no-wizard     # never ask; use vars.local.yml if present, defaults otherwise
#   ./run.sh --harden-ssh    # key-only SSH, no root login (check key login first!)
#   ./run.sh --preflight     # only run the pre-flight checks, change nothing
#   ./run.sh --tags ssh,firewall   # run only some parts (see README, "Теги")
#   ./run.sh --check         # any other option goes to ansible-playbook (dry run)
#   ./run.sh -e admin_user=alice
#
# VARS_FILE=other.yml ./run.sh   # use a different settings file

set -euo pipefail

SCRIPT=$(readlink -f "$0")
cd "$(dirname "$SCRIPT")"

VARS_FILE="${VARS_FILE:-vars.local.yml}"
export VARS_FILE

WIZARD="auto"
HARDEN_SSH=0
PREFLIGHT=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --wizard) WIZARD="force" ;;
    --wizard-only) WIZARD="only" ;;
    --no-wizard) WIZARD="never" ;;
    --harden-ssh) HARDEN_SSH=1 ;;
    --preflight) PREFLIGHT=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done

if [ "$WIZARD" = "only" ]; then
  exec ./wizard.sh
fi

# The playbook changes the system, so it needs root. Re-run through sudo; the
# wizard then knows which user called sudo (SUDO_USER) and proposes it as the
# administrator.
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Нужны права root: запустите скрипт от root или установите sudo." >&2
    exit 1
  fi
  echo "Нужны права root, перезапускаю через sudo..."
  exec sudo -- "$SCRIPT" "$@"
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ansible
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ansible-core
  else
    echo "ansible-playbook not found; install Ansible first" >&2
    exit 1
  fi
fi

# ansible-core does not ship ansible.posix/community.general; the playbook
# needs both (authorized_key, firewalld, seport, ufw).
if command -v ansible-galaxy >/dev/null 2>&1; then
  ansible-galaxy collection install -r requirements.yml
fi

# --- settings -----------------------------------------------------------------
WIZARD_RAN=0
if [ "$WIZARD" = "force" ] ||
  { [ "$WIZARD" = "auto" ] && [ ! -f "$VARS_FILE" ] && [ -t 0 ]; }; then
  ./wizard.sh
  WIZARD_RAN=1
elif [ ! -f "$VARS_FILE" ] && [ "$WIZARD" = "auto" ]; then
  echo "Файла $VARS_FILE нет, а терминала для вопросов нет: использую настройки по умолчанию."
  echo "Создать файл можно командой: ./run.sh --wizard-only"
fi

if [ "$WIZARD_RAN" -eq 1 ] && [ -t 0 ]; then
  read -r -p "Запустить настройку системы сейчас? [Y/n]: " go
  case "${go:-y}" in
    n | N | no | нет | н) echo "Файл $VARS_FILE сохранён. Запуск: sudo ./run.sh"; exit 0 ;;
  esac
fi

EXTRA=()
# Under sudo Ansible sees itself as root; default the administrator to the
# person who called sudo. A value in the settings file wins over this.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  EXTRA+=(-e "admin_user=$SUDO_USER")
fi
if [ -f "$VARS_FILE" ]; then
  echo "Использую настройки из $VARS_FILE"
  EXTRA+=(-e "@$VARS_FILE")
fi
if [ "$HARDEN_SSH" -eq 1 ]; then
  EXTRA+=(-e ssh_harden=true -e ssh_password_auth=false -e ssh_permit_root_login=no)
fi

if [ "$PREFLIGHT" -eq 1 ]; then
  EXTRA+=(-e preflight_only=true)
fi

exec ansible-playbook -i inventory.ini site.yml "${EXTRA[@]}" "${ARGS[@]}"
