#!/usr/bin/env bash
#
# Post-install verification for the Ansible hardening playbook.
# Run on the target after ansible-playbook:
#
#   sudo ./verify.sh
#
# Supports Debian/Ubuntu (apt/UFW) and the RHEL family (dnf/firewalld).
# The expected values come from /etc/ansible-setup-summary.json, so the checks
# follow the variables the playbook was run with.
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

# expect_eq NAME ACTUAL EXPECTED  -> PASS when equal, FAIL otherwise
expect_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1 is $3"
  else
    fail "$1 is '$2' (expected $3)"
  fi
}

if [ ! -r "$SUMMARY" ]; then
  echo "Missing $SUMMARY. Run the playbook first." >&2
  exit 1
fi

# Scalar value of a summary key (booleans print as True/False, lists as Python).
json_get() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$SUMMARY" "$1"
}

# True when the summary key is the boolean true.
json_true() {
  [ "$(json_get "$1")" = "True" ]
}

# True when FILE has a "key = value" line (spaces around "=" are optional,
# ansible.posix.sysctl writes "key=value").
conf_has() {
  local file="$1" key="$2" value="$3"
  local re="${key//./\\.}"
  grep -Eq "^[[:space:]]*${re}[[:space:]]*=[[:space:]]*${value}[[:space:]]*$" "$file" 2>/dev/null
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
SUDO_GROUP=$(json_get sudo_group)
FIREWALL_BACKEND=$(json_get firewall_backend)
# Entries look like "80/tcp 443/udp".
FIREWALL_ALLOWED_PORTS=$(python3 -c 'import json,sys; print(" ".join(str(p) for p in json.load(open(sys.argv[1])).get("firewall_allowed_ports", [])))' "$SUMMARY")
CROWDSEC_BOUNCER_MODE=$(json_get crowdsec_bouncer_mode)
CROWDSEC_BOUNCER_CONFIG=$(json_get crowdsec_bouncer_config)
DOCKER_DAEMON_CONFIG=$(json_get docker_daemon_config)
DOCKER_DEFAULT_BIND_IP=$(json_get docker_default_bind_ip)
JOURNALD_MAX_USE=$(json_get base_journald_max_use)
RP_FILTER=$(json_get kernel_rp_filter)
LOG_MARTIANS=$(json_get kernel_log_martians)
SSH_PERMIT_ROOT_LOGIN=$(json_get ssh_permit_root_login)

container_type=$(systemd-detect-virt --container 2>/dev/null || true)
is_container() { [ -n "$container_type" ] && [ "$container_type" != "none" ]; }

section "Summary"
info "os_family=$OS_FAMILY (package manager: $PKG_MANAGER)"
info "admin_user=$ADMIN_USER"
info "sudo_group=$SUDO_GROUP"
info "firewall=$FIREWALL_BACKEND"
info "extra_ports=${FIREWALL_ALLOWED_PORTS:-none}"

section "Packages"
if [ "$PKG_MANAGER" = "apt" ]; then
  PACKAGES="sudo curl wget mtr git openssh-server ufw crowdsec crowdsec-firewall-bouncer zram-tools docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin unattended-upgrades rsyslog"
else
  PACKAGES="sudo curl wget mtr git openssh-server firewalld crowdsec crowdsec-firewall-bouncer-nftables zram-generator docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin dnf-automatic yum-utils"
fi
if json_true base_time_sync; then
  PACKAGES="$PACKAGES chrony"
fi
for pkg in $PACKAGES; do
  if pkg_installed "$pkg" || { [ "$pkg" = "curl" ] && pkg_installed curl-minimal; }; then
    pass "package installed: $pkg"
  else
    fail "package missing: $pkg"
  fi
done

# trippy is installed from the distribution repositories only; it may be
# missing when the repositories do not provide it, so only the command is checked.
if json_true base_install_trippy; then
  if command -v trippy >/dev/null 2>&1 || command -v trip >/dev/null 2>&1; then
    pass "trippy binary is available"
  else
    skip "trippy binary is not available (not provided by the distribution repositories?)"
  fi
fi

section "SSH"
if ss -ltnH "sport = :22" | grep -q .; then
  pass "sshd is listening on port 22"
else
  fail "sshd is not listening on port 22"
fi

if sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | grep -qx 22; then
  pass "sshd effective config uses port 22"
else
  fail "sshd effective config does not use port 22"
fi

if json_true ssh_harden; then
  if json_true ssh_password_auth; then
    expected_pw="yes"
  else
    expected_pw="no"
  fi
  if sshd -T 2>/dev/null | grep -qx "passwordauthentication $expected_pw"; then
    pass "SSH password authentication is '$expected_pw' as configured"
  else
    fail "SSH password authentication is not '$expected_pw'"
  fi

  # sshd -T reports "prohibit-password" as "without-password".
  expected_root="$SSH_PERMIT_ROOT_LOGIN"
  [ "$expected_root" = "prohibit-password" ] && expected_root="(prohibit-password|without-password)"
  if sshd -T 2>/dev/null | grep -Eqx "permitrootlogin $expected_root"; then
    pass "SSH PermitRootLogin is $SSH_PERMIT_ROOT_LOGIN as configured"
  else
    fail "SSH PermitRootLogin is not $SSH_PERMIT_ROOT_LOGIN"
  fi
else
  info "SSH hardening is disabled: sshd keeps the distribution configuration"
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

  if json_true firewall_ssh_rate_limit; then
    ssh_action="LIMIT"
  else
    ssh_action="ALLOW"
  fi
  if ufw status 2>/dev/null | grep -qE "^22/tcp[[:space:]]+${ssh_action}"; then
    pass "UFW rule for SSH on port 22 is $ssh_action"
  else
    fail "UFW has no $ssh_action rule for SSH on port 22"
  fi

  for spec in $FIREWALL_ALLOWED_PORTS; do
    if ufw status 2>/dev/null | grep -qE "^${spec}[[:space:]]+ALLOW"; then
      pass "UFW allows extra port $spec"
    else
      fail "UFW does not allow extra port $spec"
    fi
  done
else
  ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || echo public)
  if systemctl is-active --quiet firewalld; then
    pass "firewalld is active"
  else
    fail "firewalld is not active"
  fi

  if firewall-cmd --zone="$ZONE" --list-services 2>/dev/null | tr ' ' '\n' | grep -qx ssh; then
    pass "firewalld allows the SSH service"
  else
    fail "firewalld does not allow the SSH service"
  fi

  for spec in $FIREWALL_ALLOWED_PORTS; do
    port="${spec%/*}"
    proto="${spec#*/}"
    # Ports without a source restriction are plain ports; restricted ones are
    # rich rules.
    if firewall-cmd --zone="$ZONE" --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx "$spec" ||
       firewall-cmd --zone="$ZONE" --list-rich-rules 2>/dev/null | grep -q "port=\"$port\" protocol=\"$proto\""; then
      pass "firewalld allows extra port $spec"
    else
      fail "firewalld does not allow extra port $spec"
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
  if json_true auto_reboot; then
    reboot_flag="true"
  else
    reboot_flag="false"
  fi
  if grep -q "Automatic-Reboot \"$reboot_flag\"" /etc/apt/apt.conf.d/52ansible-unattended-upgrades 2>/dev/null; then
    pass "unattended-upgrades automatic reboot is $reboot_flag"
  else
    fail "unattended-upgrades automatic reboot is not $reboot_flag"
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

section "Time synchronisation / journald"
if json_true base_time_sync; then
  if is_container; then
    skip "time synchronisation is left to the host inside $container_type"
  else
    if [ "$PKG_MANAGER" = "apt" ]; then
      time_unit="chrony"
    else
      time_unit="chronyd"
    fi
    if systemctl is-active --quiet "$time_unit"; then
      pass "$time_unit is active"
    else
      fail "$time_unit is not active"
    fi
  fi
fi

if [ -n "$JOURNALD_MAX_USE" ]; then
  if grep -q "^SystemMaxUse=$JOURNALD_MAX_USE" /etc/systemd/journald.conf.d/99-ansible.conf 2>/dev/null; then
    pass "journald size limit is $JOURNALD_MAX_USE"
  else
    fail "journald size limit is not configured"
  fi
fi

section "BBR / IPv6 / sysctl / zram"
if conf_has /etc/sysctl.d/99-bbr.conf net.core.default_qdisc fq &&
   conf_has /etc/sysctl.d/99-bbr.conf net.ipv4.tcp_congestion_control bbr; then
  pass "BBR sysctl configuration is present"
else
  fail "BBR sysctl configuration is incomplete"
fi

if is_container; then
  skip "BBR is not applied at runtime inside $container_type (host kernel controls it)"
else
  cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
  qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
  expect_eq "kernel congestion control" "$cc" "bbr"
  expect_eq "kernel default qdisc" "$qdisc" "fq"
fi

HARDENING=/etc/sysctl.d/99-hardening.conf
if [ -f "$HARDENING" ] &&
   conf_has "$HARDENING" net.ipv4.conf.all.rp_filter "$RP_FILTER" &&
   conf_has "$HARDENING" net.ipv4.tcp_syncookies 1 &&
   conf_has "$HARDENING" net.ipv4.conf.all.accept_redirects 0 &&
   conf_has "$HARDENING" net.ipv4.conf.all.log_martians "$LOG_MARTIANS"; then
  pass "network hardening sysctl configuration is present"
else
  fail "network hardening sysctl configuration is incomplete"
fi

if grep -q 'tcp_syn_retries' "$HARDENING" 2>/dev/null; then
  fail "obsolete net.ipv4.tcp_syn_retries is still set in $HARDENING"
fi

if is_container; then
  skip "network hardening sysctls are not applied inside $container_type"
else
  rp=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true)
  sc=$(cat /proc/sys/net/ipv4/tcp_syncookies 2>/dev/null || true)
  ar=$(cat /proc/sys/net/ipv4/conf/all/accept_redirects 2>/dev/null || true)
  expect_eq "rp_filter" "$rp" "$RP_FILTER"
  expect_eq "tcp_syncookies" "$sc" "1"
  expect_eq "accept_redirects" "$ar" "0"
fi

if json_true disable_ipv6; then
  if conf_has /etc/sysctl.d/99-disable-ipv6.conf net.ipv6.conf.all.disable_ipv6 1; then
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
else
  if [ ! -e /etc/sysctl.d/99-disable-ipv6.conf ] && [ ! -e /etc/default/grub.d/99-disable-ipv6.cfg ]; then
    pass "IPv6 stays enabled: no IPv6-disable configuration is present"
  else
    fail "IPv6 should stay enabled but IPv6-disable configuration is present"
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
  if systemctl is-active --quiet "$ZRAM_UNIT"; then
    pass "$ZRAM_UNIT is active"
  else
    fail "$ZRAM_UNIT is not active"
  fi
  if [ -e /dev/zram0 ]; then
    pass "/dev/zram0 exists"
  else
    fail "/dev/zram0 is missing"
  fi
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
  if python3 - "$DOCKER_DAEMON_CONFIG" "$DOCKER_DEFAULT_BIND_IP" <<'PY' >/dev/null 2>&1
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
opts = config.get("log-opts", {})
assert opts.get("max-size")
assert opts.get("max-file")
assert config.get("live-restore") is True
if sys.argv[2]:
    assert config.get("ip") == sys.argv[2]
PY
  then
    pass "Docker log rotation, live-restore and bind address are configured"
  else
    fail "Docker daemon configuration is incomplete: $DOCKER_DAEMON_CONFIG"
  fi
else
  fail "Docker daemon configuration is missing: $DOCKER_DAEMON_CONFIG"
fi

if json_true docker_add_admin_to_group; then
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
elif json_true admin_user_sudo_nopasswd; then
  if su - "$ADMIN_USER" -c 'sudo -n true' >/dev/null 2>&1; then
    pass "$ADMIN_USER can use sudo without a password"
  else
    fail "$ADMIN_USER cannot use sudo without a password"
  fi
elif [ ! -e "/etc/sudoers.d/90-$ADMIN_USER" ]; then
  pass "passwordless sudo is not configured for $ADMIN_USER (sudo asks for the password)"
else
  fail "/etc/sudoers.d/90-$ADMIN_USER exists although admin_user_sudo_nopasswd is false"
fi

section "Listening ports"
ALLOWED_PORTS="22"
for spec in $FIREWALL_ALLOWED_PORTS; do
  ALLOWED_PORTS="$ALLOWED_PORTS ${spec%%/*}"
done
unexpected=""
while read -r state _recvq _sendq local _peer _rest; do
  [ "$state" = "LISTEN" ] || continue
  addr="${local%:*}"
  port="${local##*:}"
  case "$addr" in
    127.*|"[::1]"|"::1"|localhost) continue ;;
  esac
  # ALLOWED_PORTS is a space-separated list; splitting it is intended.
  # shellcheck disable=SC2086
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
