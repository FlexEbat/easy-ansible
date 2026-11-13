#!/usr/bin/env bash
#
# Post-install verification for the Ansible hardening playbook.
# Run on the target after ansible-playbook:
#
#   ./verify.sh
#
# Supports Debian/Ubuntu (apt/UFW) and the RHEL family (dnf/firewalld).
# Exit code: 0 when every required check passes, 1 otherwise.

set -u

SUMMARY="/etc/ansible-setup-summary.json"
PASS=0
FAIL=0
SKIP=0

pass() { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  [SKIP] %s\n' "$*"; SKIP=$((SKIP + 1)); }
info() { printf '  [INFO] %s\n' "$*"; }

section() { printf '\n== %s ==\n' "$*"; }

if [ ! -r "$SUMMARY" ]; then
  echo "Missing $SUMMARY. Run the playbook first." >&2
  exit 1
fi

json_get() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$SUMMARY" "$1"
}

if command -v dpkg-query >/dev/null 2>&1; then
  PKG_MANAGER="apt"
  OS_FAMILY="debian"
elif command -v rpm >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
  OS_FAMILY="rhel"
else
  echo "Unsupported system: neither dpkg nor rpm found." >&2
  exit 1
fi

pkg_installed() {
  if [ "$PKG_MANAGER" = "apt" ]; then
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
  else
    rpm -q "$1" >/dev/null 2>&1
  fi
}

ADMIN_USER=$(json_get admin_user)
SSH_PORT=$(json_get ssh_port)
SSH_KEY=$(json_get ssh_private_key)
SSH_PUB=$(json_get ssh_public_key)
SSH_GENERATE_KEY=$(json_get ssh_generate_key)
ADMIN_HOME=$(json_get admin_home)
SUDO_GROUP=$(json_get sudo_group)
FIREWALL_BACKEND=$(json_get firewall_backend)
SSH_ALLOWED_FROM=$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["ssh_allowed_from"]))' "$SUMMARY")
FIREWALL_ALLOWED_PORTS=$(python3 -c 'import json,sys; print(" ".join(str(p) for p in json.load(open(sys.argv[1])).get("firewall_allowed_ports", [])))' "$SUMMARY")
CROWDSEC_BOUNCER_MODE=$(json_get crowdsec_bouncer_mode)
CROWDSEC_BOUNCER_CONFIG=$(json_get crowdsec_bouncer_config)
DOCKER_DAEMON_CONFIG=$(json_get docker_daemon_config)
DOCKER_ADD_ADMIN_TO_GROUP=$(json_get docker_add_admin_to_group)

container_type=$(systemd-detect-virt --container 2>/dev/null || true)
is_container() { [ -n "$container_type" ] && [ "$container_type" != "none" ]; }

ufw_has_source() {
  ufw status 2>/dev/null | awk -v p="${SSH_PORT}/tcp" -v src="$1" '
    {
      line = $0
      sub(/#.*/, "", line)
      sub(/[ \t]+$/, "", line)
      sub(/[ \t]+\(v6\)$/, "", line)
      sub(/[ \t]+$/, "", line)
      n = split(line, fields, /[ \t]+/)
      if (fields[1] == p && fields[n] == src) found = 1
    }
    END { exit !found }'
}

section "Summary"
info "os_family=$OS_FAMILY (package manager: $PKG_MANAGER)"
info "admin_user=$ADMIN_USER"
info "sudo_group=$SUDO_GROUP"
info "firewall=$FIREWALL_BACKEND"
info "ssh_port=$SSH_PORT"
info "ssh_key_generation=$SSH_GENERATE_KEY"
info "extra_ports=${FIREWALL_ALLOWED_PORTS:-none}"

section "Packages"
if [ "$PKG_MANAGER" = "apt" ]; then
  PACKAGES="sudo curl wget mtr git openssh-server ufw crowdsec crowdsec-firewall-bouncer zram-tools trippy docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin unattended-upgrades rsyslog"
else
  PACKAGES="sudo curl wget mtr git openssh-server firewalld crowdsec crowdsec-firewall-bouncer-nftables zram-generator docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin dnf-automatic yum-utils"
fi
for pkg in $PACKAGES; do
  if pkg_installed "$pkg" || { [ "$pkg" = "curl" ] && pkg_installed curl-minimal; }; then
    pass "package installed: $pkg"
  else
    fail "package missing: $pkg"
  fi
done

# trippy may be a package (x86_64) or a plain binary on other architectures.
if command -v trippy >/dev/null 2>&1 || command -v trip >/dev/null 2>&1; then
  pass "trippy binary is available"
else
  fail "trippy binary is not available"
fi

section "SSH"
PORT_FILE=$(tr -d '[:space:]' < /etc/ansible-ssh-port 2>/dev/null || true)
if [ "$PORT_FILE" = "$SSH_PORT" ]; then
  pass "persisted port matches summary ($SSH_PORT)"
else
  fail "persisted port '$PORT_FILE' does not match summary '$SSH_PORT'"
fi

if [ "$SSH_PORT" -ge 20000 ] && [ "$SSH_PORT" -le 32000 ] && [ "$SSH_PORT" -ne 22 ]; then
  pass "port $SSH_PORT is in the expected random range"
else
  fail "port $SSH_PORT is outside the expected range or is 22"
fi

if sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | grep -qx "$SSH_PORT"; then
  pass "sshd effective config uses port $SSH_PORT"
else
  fail "sshd effective config does not use port $SSH_PORT"
fi

if ss -ltnH "sport = :$SSH_PORT" | grep -q .; then
  pass "sshd is listening on $SSH_PORT"
else
  fail "sshd is not listening on $SSH_PORT"
fi

if sshd -T 2>/dev/null | grep -qx 'addressfamily inet'; then
  pass "sshd listens on IPv4 only (AddressFamily inet)"
else
  fail "sshd address family is not 'inet'"
fi

# Ubuntu 22.10+ / 24.04 use ssh.socket, which ignores the Port directive.
if systemctl list-unit-files ssh.socket 2>/dev/null | grep -q '^ssh.socket'; then
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    fail "ssh.socket is enabled (it keeps sshd on the socket's port)"
  else
    pass "ssh.socket is disabled"
  fi
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    fail "ssh.socket is active"
  else
    pass "ssh.socket is not active"
  fi
else
  skip "ssh.socket is not present on this system"
fi

if [ "$SSH_GENERATE_KEY" = "True" ] || [ "$SSH_GENERATE_KEY" = "true" ]; then
  if [ -f "$SSH_KEY" ]; then
    pass "private key exists: $SSH_KEY"
    key_mode=$(stat -c '%a' "$SSH_KEY")
    key_owner=$(stat -c '%U' "$SSH_KEY")
    [ "$key_mode" = "600" ] && pass "private key mode is 600" || fail "private key mode is $key_mode (expected 600)"
    [ "$key_owner" = "$ADMIN_USER" ] && pass "private key owner is $ADMIN_USER" || fail "private key owner is $key_owner (expected $ADMIN_USER)"
  else
    fail "private key is missing: $SSH_KEY"
  fi
else
  skip "server-side key generation is disabled"
fi

if [ -f "$ADMIN_HOME/.ssh/authorized_keys" ] && [ -s "$ADMIN_HOME/.ssh/authorized_keys" ]; then
  pass "authorized_keys is not empty"
else
  fail "authorized_keys is empty or missing for $ADMIN_USER"
fi

if [ -f "$SSH_PUB" ]; then
  key_body=$(awk '{print $1" "$2}' "$SSH_PUB")
  if grep -qF "$key_body" "$ADMIN_HOME/.ssh/authorized_keys" 2>/dev/null; then
    pass "generated public key is authorized for $ADMIN_USER"
  else
    fail "generated public key is not present in $ADMIN_HOME/.ssh/authorized_keys"
  fi
else
  skip "no server-generated public key to compare"
fi

if sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
  pass "SSH password authentication is disabled"
else
  fail "SSH password authentication is not disabled"
fi

if sshd -T 2>/dev/null | grep -qx 'pubkeyauthentication yes'; then
  pass "SSH public-key authentication is enabled"
else
  fail "SSH public-key authentication is not enabled"
fi

if sshd -T 2>/dev/null | grep -qx 'permitemptypasswords no'; then
  pass "empty passwords are rejected"
else
  fail "PermitEmptyPasswords is not 'no'"
fi

if sshd -T 2>/dev/null | grep -qx 'allowagentforwarding no'; then
  pass "SSH agent forwarding is disabled"
else
  fail "SSH agent forwarding is not disabled"
fi

if sshd -T 2>/dev/null | grep -qix 'loglevel verbose'; then
  pass "sshd log level is VERBOSE"
else
  fail "sshd log level is not VERBOSE"
fi

allowusers=$(sshd -T 2>/dev/null | awk '$1=="allowusers"{$1=""; print substr($0,2)}')
if printf '%s\n' "$allowusers" | tr ' ' '\n' | grep -qx "$ADMIN_USER"; then
  pass "AllowUsers includes $ADMIN_USER"
else
  fail "AllowUsers does not include $ADMIN_USER (current: ${allowusers:-empty})"
fi

prl=$(sshd -T 2>/dev/null | awk '$1=="permitrootlogin"{print $2}')
if [ "$ADMIN_USER" = "root" ]; then
  if [ "$prl" != "yes" ]; then
    pass "root password login is disabled (permitrootlogin=$prl)"
  else
    fail "permitrootlogin is 'yes'"
  fi
else
  if [ "$prl" = "no" ]; then
    pass "root login is disabled (permitrootlogin=no)"
  else
    fail "permitrootlogin is '$prl' (expected no for admin_user=$ADMIN_USER)"
  fi
fi

section "Firewall ($FIREWALL_BACKEND)"
if [ "$FIREWALL_BACKEND" = "ufw" ]; then
  if ufw status verbose 2>/dev/null | grep -q 'Status: active'; then
    pass "UFW is active"
  else
    fail "UFW is not active"
  fi

  if ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming)'; then
    pass "UFW default incoming policy is deny"
  else
    fail "UFW default incoming policy is not deny"
  fi

  if [ "$SSH_ALLOWED_FROM" = "any" ]; then
    if ufw_has_source "Anywhere"; then
      pass "UFW allows the new SSH port $SSH_PORT from anywhere"
    else
      fail "UFW does not allow the new SSH port $SSH_PORT from anywhere"
    fi
  else
    all_ok=1
    IFS=',' read -ra CIDRS <<< "$SSH_ALLOWED_FROM"
    for cidr in "${CIDRS[@]}"; do
      if ! ufw_has_source "$cidr"; then
        all_ok=0
      fi
    done
    if [ "$all_ok" = "1" ]; then
      pass "UFW restricts the new SSH port to: $SSH_ALLOWED_FROM"
    else
      fail "UFW does not restrict port $SSH_PORT to: $SSH_ALLOWED_FROM"
    fi
    if ufw_has_source "Anywhere"; then
      fail "UFW still allows the new SSH port from anywhere"
    else
      pass "UFW has no stale allow-any rule for port $SSH_PORT"
    fi
  fi

  if ufw status 2>/dev/null | grep -qE '^22/tcp[[:space:]]+DENY'; then
    pass "UFW denies the default SSH port 22"
  else
    fail "UFW does not explicitly deny port 22"
  fi

  for port in $FIREWALL_ALLOWED_PORTS; do
    if ufw status 2>/dev/null | grep -qE "^${port}/tcp[[:space:]]+ALLOW"; then
      pass "UFW allows extra port $port/tcp"
    else
      fail "UFW does not allow extra port $port/tcp"
    fi
  done
else
  ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || echo public)
  if systemctl is-active --quiet firewalld; then
    pass "firewalld is active"
  else
    fail "firewalld is not active"
  fi

  if [ "$SSH_ALLOWED_FROM" = "any" ]; then
    if firewall-cmd --zone="$ZONE" --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx "$SSH_PORT/tcp"; then
      pass "firewalld allows the new SSH port $SSH_PORT"
    else
      fail "firewalld does not allow the new SSH port $SSH_PORT"
    fi
    if firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null | grep -q "port port=\"$SSH_PORT\""; then
      fail "firewalld still has source-restricted rules for port $SSH_PORT"
    else
      pass "firewalld has no stale source-restricted rules for port $SSH_PORT"
    fi
  else
    rich=$(firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null || true)
    all_ok=1
    IFS=',' read -ra CIDRS <<< "$SSH_ALLOWED_FROM"
    for cidr in "${CIDRS[@]}"; do
      if ! printf '%s\n' "$rich" | grep -q "source address=\"$cidr\".*port=\"$SSH_PORT\""; then
        all_ok=0
      fi
    done
    if [ "$all_ok" = "1" ]; then
      pass "firewalld restricts the new SSH port to: $SSH_ALLOWED_FROM"
    else
      fail "firewalld rich rules do not restrict port $SSH_PORT to: $SSH_ALLOWED_FROM"
    fi
  fi

  if firewall-cmd --zone="$ZONE" --list-services 2>/dev/null | tr ' ' '\n' | grep -qx ssh; then
    fail "firewalld still allows the default SSH service"
  else
    pass "firewalld does not allow the default SSH service"
  fi

  if firewall-cmd --zone="$ZONE" --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx '22/tcp'; then
    fail "firewalld still allows port 22/tcp"
  else
    pass "firewalld does not allow port 22/tcp"
  fi

  for port in $FIREWALL_ALLOWED_PORTS; do
    if firewall-cmd --zone="$ZONE" --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx "$port/tcp"; then
      pass "firewalld allows extra port $port/tcp"
    else
      fail "firewalld does not allow extra port $port/tcp"
    fi
  done
fi

section "CrowdSec"
if systemctl is-active --quiet crowdsec; then
  pass "crowdsec service is active"
else
  fail "crowdsec service is not active"
fi

if systemctl is-active --quiet crowdsec-firewall-bouncer; then
  pass "crowdsec-firewall-bouncer service is active"
else
  fail "crowdsec-firewall-bouncer service is not active"
fi

if cscli lapi status >/dev/null 2>&1; then
  pass "CrowdSec Local API is reachable"
else
  fail "CrowdSec Local API is not reachable"
fi

if cscli metrics >/dev/null 2>&1; then
  pass "CrowdSec metrics can be read (cscli metrics)"
elif curl -fsS http://127.0.0.1:6060/metrics 2>/dev/null | grep -q '^cs_filesource_hits_total'; then
  # CrowdSec 1.4.x (Ubuntu 24.04) can crash in "cscli metrics" while decoding
  # the Prometheus payload; the endpoint itself is healthy.
  pass "CrowdSec metrics can be read (Prometheus endpoint)"
else
  fail "CrowdSec metrics are unavailable (check rsyslog and /var/log/auth.log)"
fi

if cscli collections list 2>/dev/null | grep -q 'crowdsecurity/sshd'; then
  pass "CrowdSec sshd collection is installed"
else
  fail "CrowdSec sshd collection is missing"
fi

if cscli parsers list 2>/dev/null | grep -q 'crowdsecurity/whitelists'; then
  pass "CrowdSec whitelists parser is installed"
else
  fail "CrowdSec whitelists parser is missing"
fi

if [ -f /etc/crowdsec/parsers/s02-enrich/ansible-whitelist.yaml ]; then
  pass "CrowdSec whitelist configuration is present"
else
  fail "CrowdSec whitelist configuration is missing"
fi

if cscli bouncers list 2>/dev/null | grep -qi 'FirewallBouncer\|firewall-bouncer'; then
  pass "a CrowdSec firewall bouncer is registered"
else
  fail "no CrowdSec firewall bouncer is registered"
fi

if [ -f "$CROWDSEC_BOUNCER_CONFIG.local" ]; then
  mode=$(awk '$1=="mode:"{print $2; exit}' "$CROWDSEC_BOUNCER_CONFIG.local")
  if [ "$mode" = "$CROWDSEC_BOUNCER_MODE" ]; then
    pass "bouncer mode matches the firewall backend ($mode)"
  else
    fail "bouncer mode is '$mode' (expected '$CROWDSEC_BOUNCER_MODE')"
  fi
fi

if [ "$PKG_MANAGER" = "apt" ]; then
  if systemctl is-active --quiet rsyslog; then
    pass "rsyslog is active"
  else
    fail "rsyslog is not active (CrowdSec needs /var/log/auth.log)"
  fi
  if [ -f /var/log/auth.log ]; then
    pass "/var/log/auth.log exists"
  else
    fail "/var/log/auth.log is missing"
  fi
fi

section "Automatic updates"
if [ "$PKG_MANAGER" = "apt" ]; then
  if grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
    pass "unattended-upgrades is enabled"
  else
    fail "unattended-upgrades is not enabled"
  fi
  if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    pass "unattended-upgrades service is active"
  else
    skip "unattended-upgrades service is not active (timer-based or missing unit)"
  fi
else
  if grep -q '^apply_updates = yes' /etc/dnf/automatic.conf 2>/dev/null; then
    pass "dnf-automatic applies updates"
  else
    fail "dnf-automatic is not configured to apply updates"
  fi
  if systemctl is-active --quiet dnf-automatic.timer 2>/dev/null; then
    pass "dnf-automatic.timer is active"
  else
    fail "dnf-automatic.timer is not active"
  fi
fi

section "BBR / IPv6 / sysctl / zram"
if grep -q '^net.core.default_qdisc = fq' /etc/sysctl.d/99-bbr.conf 2>/dev/null &&
   grep -q '^net.ipv4.tcp_congestion_control = bbr' /etc/sysctl.d/99-bbr.conf 2>/dev/null; then
  pass "BBR sysctl configuration is present"
else
  fail "BBR sysctl configuration is incomplete"
fi

if is_container; then
  skip "BBR is not applied at runtime inside $container_type (host kernel controls it)"
else
  cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
  qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
  [ "$cc" = "bbr" ] && pass "kernel is using BBR" || fail "kernel congestion control is '$cc' (expected bbr)"
  [ "$qdisc" = "fq" ] && pass "kernel default qdisc is fq" || fail "kernel default qdisc is '$qdisc' (expected fq)"
fi

if [ -f /etc/sysctl.d/99-hardening.conf ] &&
   grep -q '^net.ipv4.conf.all.rp_filter = 1' /etc/sysctl.d/99-hardening.conf &&
   grep -q '^net.ipv4.tcp_syncookies = 1' /etc/sysctl.d/99-hardening.conf &&
   grep -q '^net.ipv4.conf.all.accept_redirects = 0' /etc/sysctl.d/99-hardening.conf; then
  pass "network hardening sysctl configuration is present"
else
  fail "network hardening sysctl configuration is incomplete"
fi

if is_container; then
  skip "network hardening sysctls are not applied inside $container_type"
else
  rp=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true)
  sc=$(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null || true)
  ar=$(cat /proc/sys/net/ipv4/conf/all/accept_redirects 2>/dev/null || true)
  [ "$rp" = "1" ] && pass "rp_filter is enabled" || fail "rp_filter is '$rp' (expected 1)"
  [ "$sc" = "1" ] && pass "SYN cookies are enabled" || fail "tcp_syncookies is '$sc' (expected 1)"
  [ "$ar" = "0" ] && pass "ICMP redirects are ignored" || fail "accept_redirects is '$ar' (expected 0)"
fi

if grep -q '^net.ipv6.conf.all.disable_ipv6 = 1' /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null; then
  pass "IPv6-disable sysctl configuration is present"
else
  fail "IPv6-disable sysctl configuration is missing"
fi

if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo '?')" = "1" ]; then
  pass "IPv6 is disabled at runtime"
elif [ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ] &&
     grep -qw 'ipv6.disable=1' /proc/cmdline 2>/dev/null; then
  pass "IPv6 is disabled by the kernel command line (sysctl is absent after reboot)"
else
  fail "IPv6 is not disabled at runtime"
fi

if [ "$PKG_MANAGER" = "apt" ]; then
  if [ -f /etc/default/grub.d/99-disable-ipv6.cfg ]; then
    pass "GRUB IPv6-disable drop-in is present"
    if [ -f /boot/grub/grub.cfg ] && grep -q 'ipv6.disable=1' /boot/grub/grub.cfg; then
      pass "GRUB configuration contains ipv6.disable=1"
    elif [ -f /boot/grub/grub.cfg ]; then
      fail "GRUB configuration does not contain ipv6.disable=1"
    else
      skip "GRUB is not installed (container)"
    fi
  else
    fail "GRUB IPv6-disable drop-in is missing"
  fi
else
  if is_container; then
    skip "kernel command line cannot be changed inside $container_type"
  else
    if grubby --info=ALL 2>/dev/null | grep -q 'ipv6.disable=1' ||
       grep -q 'ipv6.disable=1' /boot/grub2/grub.cfg 2>/dev/null; then
      pass "kernel command line contains ipv6.disable=1"
    else
      fail "kernel command line does not contain ipv6.disable=1"
    fi
  fi
fi

if [ "$PKG_MANAGER" = "apt" ]; then
  if grep -q '^ALGO=zstd' /etc/default/zramswap 2>/dev/null &&
     grep -q '^PERCENT=25' /etc/default/zramswap 2>/dev/null &&
     grep -q '^PRIORITY=100' /etc/default/zramswap 2>/dev/null; then
    pass "zram configuration is present (zstd, 25%, priority 100)"
  else
    fail "zram configuration is incomplete"
  fi
  ZRAM_UNIT="zramswap"
else
  if grep -q '^\[zram0\]' /etc/systemd/zram-generator.conf 2>/dev/null &&
     grep -q '^compression-algorithm = zstd' /etc/systemd/zram-generator.conf 2>/dev/null &&
     grep -q '^swap-priority = 100' /etc/systemd/zram-generator.conf 2>/dev/null; then
    pass "zram-generator configuration is present (zstd, priority 100)"
  else
    fail "zram-generator configuration is incomplete"
  fi
  ZRAM_UNIT="systemd-zram-setup@zram0.service"
fi

if is_container; then
  skip "zram is not startable inside $container_type (no zram device)"
else
  systemctl is-active --quiet "$ZRAM_UNIT" && pass "$ZRAM_UNIT is active" || fail "$ZRAM_UNIT is not active"
  [ -e /dev/zram0 ] && pass "/dev/zram0 exists" || fail "/dev/zram0 is missing"
fi

section "Docker"
if systemctl is-active --quiet docker; then
  pass "docker service is active"
else
  fail "docker service is not active"
fi

if docker info >/dev/null 2>&1; then
  pass "Docker daemon responds"
else
  fail "Docker daemon does not respond"
fi

if docker --version 2>/dev/null | grep -q 'Docker version'; then
  pass "Docker CE is installed ($(docker --version 2>/dev/null))"
else
  fail "Docker CE is not installed"
fi

if [ -f "$DOCKER_DAEMON_CONFIG" ]; then
  if python3 - "$DOCKER_DAEMON_CONFIG" <<'PY' >/dev/null 2>&1
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
opts = config.get("log-opts", {})
assert opts.get("max-size")
assert opts.get("max-file")
assert config.get("live-restore") is True
PY
  then
    pass "Docker log rotation and live-restore are configured"
  else
    fail "Docker daemon configuration is incomplete: $DOCKER_DAEMON_CONFIG"
  fi
else
  fail "Docker daemon configuration is missing: $DOCKER_DAEMON_CONFIG"
fi

if [ "$DOCKER_ADD_ADMIN_TO_GROUP" = "True" ] || [ "$DOCKER_ADD_ADMIN_TO_GROUP" = "true" ]; then
  if [ "$ADMIN_USER" = "root" ] || id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    pass "$ADMIN_USER can access the Docker socket group"
  else
    fail "$ADMIN_USER is not a member of the docker group"
  fi
fi

section "Sudo user"
if [ "$ADMIN_USER" = "root" ]; then
  pass "admin user root does not need the $SUDO_GROUP group"
elif id -nG "$ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$SUDO_GROUP"; then
  pass "$ADMIN_USER is a member of the $SUDO_GROUP group"
else
  fail "$ADMIN_USER is not a member of the $SUDO_GROUP group"
fi

if [ "$ADMIN_USER" = "root" ]; then
  pass "admin user is root (full privileges)"
elif su - "$ADMIN_USER" -c 'sudo -n true' >/dev/null 2>&1; then
  pass "$ADMIN_USER can use sudo without a password"
else
  fail "$ADMIN_USER cannot use sudo without a password"
fi

section "Listening ports"
ALLOWED_PORTS="$SSH_PORT $FIREWALL_ALLOWED_PORTS"
unexpected=""
while read -r state _recvq _sendq local _peer _rest; do
  [ "$state" = "LISTEN" ] || continue
  addr="${local%:*}"
  port="${local##*:}"
  case "$addr" in
    127.*|"[::1]"|"::1"|localhost) continue ;;
  esac
  if ! printf '%s\n' $ALLOWED_PORTS | grep -qx "$port"; then
    unexpected="$unexpected $local"
  fi
done < <(ss -H -tln 2>/dev/null)
if [ -z "$unexpected" ]; then
  pass "no unexpected external TCP listeners"
else
  fail "unexpected external TCP listeners:$unexpected"
fi

section "Reboot"
if [ -e /var/run/reboot-required ]; then
  pkgs=$(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null || true)
  info "reboot required (pending: ${pkgs:-package updates})"
elif command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then
  info "reboot required (needs-restarting)"
else
  info "no reboot required"
fi

printf '\n== Result ==\n'
printf '  passed: %d, failed: %d, skipped: %d\n' "$PASS" "$FAIL" "$SKIP"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
