#!/usr/bin/env bash
#
# Bootstrap Ansible on a fresh Debian/Ubuntu or RHEL-family target and run the
# playbook.
# Usage:
#   ./run.sh                         # uses $USER / SUDO_USER
#   ./run.sh -e admin_user=alice     # explicit admin user
#   ./run.sh --check                 # dry run

set -euo pipefail
cd "$(dirname "$0")"

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

exec ansible-playbook -i inventory.ini site.yml "$@"
