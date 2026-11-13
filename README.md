# Hardening playbook для Debian, Ubuntu и RHEL

Ansible-плейбук приводит чистый сервер (или LXC/Docker-контейнер) к состоянию:

1. Определяет ОС и обновляет все пакеты (`apt dist-upgrade` или `dnf upgrade`).
2. Переносит SSH на случайный порт, закрывает порт 22, запрещает вход по
   паролю, добавляет ваш публичный ключ или генерирует `ed25519` на сервере.
3. Устанавливает `sudo`, `curl`/`curl-minimal`, `wget`, `mtr`, `trippy`, `git`,
   `zram`, `CrowdSec`, официальный `Docker CE` и автообновления.
4. Настраивает firewall, CrowdSec (+ firewall bouncer), BBR, отключение IPv6,
   сетевые sysctl и zram.
5. Проверяет, что `admin_user` есть в группе администраторов; если нет —
   создаёт пользователя и настраивает sudo.
6. Сообщает, требуется ли перезагрузка после обновления.

## Поддерживаемые ОС

| Семейство | Дистрибутивы | Пакеты | Firewall | sudo-группа | zram |
|---|---|---|---|---|---|
| Debian | Debian 13+, Ubuntu 24.04+ | `apt` | `ufw` | `sudo` | `zram-tools` |
| RHEL | RHEL 8/9, AlmaLinux, Rocky, CentOS Stream, Oracle Linux | `dnf` | `firewalld` | `wheel` | `zram-generator` |

Debian 12 и Ubuntu 22.04 больше не поддерживаются: для них нет актуальных
пакетов CrowdSec/Docker в нужной конфигурации. Плейбук проверяет ОС в начале и
останавливается с понятной ошибкой на неподдерживаемой системе.

## Структура

```
.
├── ansible.cfg
├── inventory.ini
├── site.yml
├── group_vars/all.yml
├── requirements.yml
├── run.sh
├── verify.sh
├── .ansible-lint
├── .yamllint
├── .github/workflows/ci.yml
├── molecule/default/          # Molecule-сценарий (Debian 13, Ubuntu 24.04, Rocky 9)
└── roles/
    ├── base/          # обновление, пакеты, автообновления, trippy
    ├── admin_user/    # admin_user, группа sudo/wheel, sudoers
    ├── ssh/           # порт, sshd_config, ключи, SELinux
    ├── firewall/      # UFW или firewalld
    ├── reconnect/     # переподключение после смены SSH-порта
    ├── crowdsec/      # сервис, LAPI, collections, bouncer, whitelist
    ├── kernel/        # BBR, IPv6, sysctl hardening, zram
    └── docker/        # официальный Docker CE и daemon.json
```

## Быстрый запуск (LXC linux-lab)

Из хоста:

```bash
# скопировать проект в контейнер
tar -C "$HOME" -czf - ansible | lxc exec linux-lab -- bash -lc 'tar -xzf - -C /root'

# запустить; admin_user по умолчанию равен ansible_user
lxc exec linux-lab -- bash -lc 'cd /root/ansible && ./run.sh -e admin_user=labadmin'

# проверить всё
lxc exec linux-lab -- bash -lc 'cd /root/ansible && ./verify.sh'
```

Либо просто зайти в контейнер и работать там:

```bash
lxc exec linux-lab -- bash
cd /root/ansible
./run.sh -e admin_user=labadmin
./verify.sh
```

`run.sh` при необходимости сам ставит Ansible (`apt` или `dnf`) и коллекции
`ansible.posix` / `community.general` из `requirements.yml`.

Для удалённого сервера:

```bash
ansible-playbook -i inventory.ini site.yml -e admin_user=admin
```

`admin_user` по умолчанию — `ansible_user` (аккаунт, под которым Ansible
подключается к хосту), а не `$USER` на control node. Это важно при запуске с
ноутбука: без `-e admin_user=...` будет выбран именно удалённый пользователь.

## Где лежит ключ, порт и итоги

После запуска на сервере есть файл `/etc/ansible-setup-summary.json`:

```json
{
  "admin_home": "/home/labadmin",
  "admin_user": "labadmin",
  "auto_updates_enabled": true,
  "crowdsec_bouncer_mode": "iptables",
  "distribution": "Debian",
  "distribution_version": "13.7",
  "docker_add_admin_to_group": true,
  "firewall_allowed_ports": [],
  "firewall_backend": "ufw",
  "os_family": "Debian",
  "reboot_required": false,
  "ssh_allowed_from": ["any"],
  "ssh_generate_key": true,
  "ssh_port": 22911,
  "ssh_port_file": "/etc/ansible-ssh-port",
  "ssh_private_key": "/home/labadmin/.ssh/id_ed25519",
  "ssh_public_key": "/home/labadmin/.ssh/id_ed25519.pub",
  "sudo_group": "sudo"
}
```

Плейбук также печатает эти значения в задаче `Show setup summary`. Порт
сохраняется в `/etc/ansible-ssh-port`, поэтому повторные запуски не меняют его
и остаются идемпотентными.

> После первого запуска SSH уже слушает новый порт. Добавьте его в inventory
> для следующих запусков:
> `prod-01 ansible_host=203.0.113.10 ansible_user=admin ansible_port=<порт>`.
> Host key checking в `ansible.cfg` не отключён; заранее добавьте ключ хоста в
> `known_hosts` (`ssh-keyscan -p <порт> <host> >> ~/.ssh/known_hosts`).

Чтобы забрать приватный ключ в LXC и проверить вход:

```bash
PORT=$(lxc exec linux-lab -- cat /etc/ansible-ssh-port)
lxc file pull linux-lab/home/labadmin/.ssh/id_ed25519 ./id_ed25519
chmod 600 ./id_ed25519

ssh -i ./id_ed25519 -p "$PORT" labadmin@10.54.26.247
```

Для удалённого сервера можно включить автоматическое копирование ключа на
control node:

```bash
ansible-playbook site.yml -e ssh_key_fetch=true
# ключ появится в ./artifacts/<host>_id_ed25519
```

`artifacts/` добавлен в `.gitignore`.

## Переменные

Основные переменные лежат в `group_vars/all.yml`.

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `admin_user` | `ansible_user` | пользователь, которого проверяем/добавляем в sudo/wheel |
| `admin_user_sudo_nopasswd` | `true` | беспарольный sudo для key-only пользователя |
| `ssh_port_min` / `ssh_port_max` | `20000` / `32000` | диапазон случайного порта |
| `ssh_password_authentication` | `false` | вход по паролю |
| `ssh_permit_root_login` | `prohibit-password` | root только по ключу (если `admin_user=root`) |
| `ssh_authorized_keys` | `[]` | публичные ключи с control node для `admin_user` |
| `ssh_generate_key` | `true` | генерировать ключ на сервере, если своих ключей нет |
| `ssh_allow_users` | `[]` | дополнительные пользователи в `AllowUsers` |
| `ssh_agent_forwarding` | `false` | разрешить agent forwarding |
| `ssh_allowed_cidrs` | `[]` | `[]` = новый порт открыт всем; иначе только подсети |
| `ssh_key_fetch` | `false` | копировать приватный ключ на control node |
| `firewall_allowed_ports` | `[]` | дополнительные порты (например, 80/443) |
| `auto_updates_enabled` | `true` | unattended-upgrades / dnf-automatic |
| `zram_percent` | `25` | сколько RAM отдать под zram |
| `zram_algorithm` | `zstd` | алгоритм сжатия zram |
| `zram_priority` | `100` | приоритет swap для zram |
| `crowdsec_whitelist_ips` | `[]` | IP, которые CrowdSec никогда не заблокирует |
| `crowdsec_whitelist_cidrs` | `[]` | подсети-исключения CrowdSec |
| `docker_service_enabled` | `true` | включает/выключает Docker |
| `docker_add_admin_to_group` | `true` | добавить `admin_user` в группу `docker` |
| `docker_log_max_size` | `10m` | ротация логов Docker |
| `docker_log_max_file` | `3` | число файлов ротации |
| `docker_live_restore` | `true` | не останавливать контейнеры при рестарте daemon |

Пример ограничения SSH только локальными сетями:

```bash
ansible-playbook site.yml \
  -e admin_user=alice \
  -e '{"ssh_allowed_cidrs":["10.0.0.0/8","192.168.0.0/16"]}'
```

Пример дополнительных портов:

```bash
ansible-playbook site.yml -e '{"firewall_allowed_ports":[
  {"port": 80, "proto": "tcp"},
  {"port": 443, "proto": "tcp"},
  {"port": 5432, "proto": "tcp", "from": "10.0.0.0/8"}
]}'
```

## Что именно настраивается

### Пакеты и автообновления

- Обновляются все пакеты; на Debian/Ubuntu используется
  `force-confdef,force-confold`, чтобы не ломать существующие конфиги.
- Debian/Ubuntu: настраивается `unattended-upgrades`; RHEL: `dnf-automatic`
  (`upgrade_type = default`, `apply_updates` управляется
  `auto_updates_enabled`).
- `trippy` ставится из репозитория дистрибутива, если доступен; иначе
  загружается upstream-артефакт с проверкой SHA-256 (`.deb` для amd64/RPM для
  x86_64, tarball для остальных архитектур).
- В конце проверяется `/var/run/reboot-required` (Debian/Ubuntu) или
  `needs-restarting -r` (RHEL), результат попадает в summary и выводится
  предупреждение.

### SSH

- `Port <random>` в `/etc/ssh/sshd_config.d/00-ansible-hardening.conf`;
  конфликтующие `Port` в основном конфиге и других drop-in файлах
  комментируются.
- `AddressFamily inet`, `PasswordAuthentication no`, `PermitEmptyPasswords no`,
  `AllowAgentForwarding no`, `X11Forwarding no`, `MaxAuthTries 3`,
  `LoginGraceTime 30`, `LogLevel VERBOSE`.
- `KbdInteractiveAuthentication` (OpenSSH 8.7+) или
  `ChallengeResponseAuthentication` (старее) выключается автоматически.
- `PermitRootLogin no`, если `admin_user != root`; иначе
  `prohibit-password`.
- `AllowUsers` всегда содержит `admin_user` плюс `ssh_allow_users`.
- Публичные ключи из `ssh_authorized_keys` добавляются в
  `~/.ssh/authorized_keys`. Если ключей нет и `ssh_generate_key=true`,
  генерируется `ed25519`.
- Перед отключением паролей плейбук проверяет, что у `admin_user` есть хотя бы
  один авторизованный ключ, и падает до записи конфигурации иначе.
- На RHEL с SELinux новый порт добавляется в `ssh_port_t` через
  `semanage`/`community.general.seport`.
- На Ubuntu 22.10+/24.04 отключается `ssh.socket`, иначе socket activation
  продолжает слушать старый порт.
- После смены порта роль `reconnect` делает
  `set_fact: ansible_port=<новый>`, `meta: reset_connection` и
  `wait_for_connection` (кроме `local`/не-SSH подключений).
- Конфиг проверяется через `sshd -t` до перезапуска.

### Firewall

- Debian/Ubuntu: UFW, default incoming `deny`, outgoing `allow`, routed `deny`.
  Новый SSH-порт разрешён; `22/tcp` явно запрещён.
- RHEL: firewalld, зона по умолчанию или `firewalld_zone`. Новый SSH-порт
  открывается, сервис `ssh` и `22/tcp` удаляются.
- Если задан `ssh_allowed_cidrs`, вместо открытого порта создаются правила
  только для указанных source. Список приводится к целевому состоянию: при
  переходе `[]` ↔ список и при удалении подсети лишние правила удаляются
  (UFW и firewalld rich rules).
- `firewall_allowed_ports` добавляет произвольные порты; поле `from`
  ограничивает источник.

### CrowdSec

- Debian/Ubuntu: `crowdsec`, `crowdsec-firewall-bouncer` и `ipset` из
  репозитория дистрибутива.
- RHEL: официальный репозиторий CrowdSec на packagecloud, пакеты `crowdsec` и
  `crowdsec-firewall-bouncer-nftables`.
- Режим bouncer выбирается по firewall: `iptables` для UFW, `nftables` для
  firewalld.
- Сервисы включаются и запускаются; плейбук ждёт Local API.
- Доустанавливаются коллекции `crowdsecurity/linux` и `crowdsecurity/sshd`,
  парсер `crowdsecurity/whitelists`.
- Whitelist включает loopback, собственный IP хоста и всё из
  `crowdsec_whitelist_ips` / `crowdsec_whitelist_cidrs`.
- На Debian 13 ставится и включается `rsyslog`, иначе CrowdSec не видит
  `/var/log/auth.log`.
- Bouncer регистрируется автоматически пакетом; если пакет оставил
  placeholder-ключ и `/var/lib/crowdsec/pending-registration`, плейбук создаёт
  bouncer через `cscli bouncers add` и удаляет маркер.
- `cscli metrics` проверяется с fallback на Prometheus-эндпоинт
  `127.0.0.1:6060`, потому что в CrowdSec 1.4.6 на Ubuntu метрики могут падать
  с ошибкой protobuf.

### BBR, IPv6 и sysctl hardening

- BBR: `/etc/sysctl.d/99-bbr.conf` с `fq` и `bbr`; на реальном хосте
  загружаются модули и применяется `sysctl -p`.
- IPv6: `/etc/sysctl.d/99-disable-ipv6.conf`, GRUB drop-in
  `/etc/default/grub.d/99-disable-ipv6.cfg` и `ipv6.disable=1` (Debian/Ubuntu —
  `update-grub`, RHEL — `grubby`).
- Сетевые sysctl (`/etc/sysctl.d/99-hardening.conf`): `rp_filter`,
  SYN cookies, защита от source routing и ICMP redirects, логирование martian
  пакетов. `net.ipv4.ip_forward` намеренно **не** отключается — он нужен
  Docker.
- В контейнерах (`lxc`, `docker`, `podman`, `containerd`, `systemd-nspawn`)
  запись конфигов выполняется, но применение kernel-настроек пропускается:
  ядром управляет хост.

### zram

- Debian/Ubuntu: `/etc/default/zramswap` — `ALGO=zstd`, `PERCENT=25`,
  `PRIORITY=100`; сервис включается, если доступен модуль/устройство zram.
- RHEL: `/etc/systemd/zram-generator.conf` — `[zram0]`,
  `zram-size = ram * 25 / 100`, `compression-algorithm = zstd`,
  `swap-priority = 100`.
- В контейнерах zram не запускается, даже если модуль виден.

### Docker (официальный Docker CE, не `docker.io`)

- Debian/Ubuntu: GPG-ключ Docker в `/etc/apt/keyrings/docker.asc`,
  репозиторий с `VERSION_CODENAME` и `dpkg --print-architecture`.
- RHEL: `dnf-plugins-core`, затем `docker-ce.repo`; AlmaLinux/Rocky/CentOS
  используют flavor `centos`, RHEL — `rhel`.
- Удаляются конфликтующие пакеты дистрибутива (`docker.io`, `podman`, `runc`
  и т. п.), ставятся `docker-ce`, `docker-ce-cli`, `containerd.io`,
  `docker-buildx-plugin`, `docker-compose-plugin`.
- `/etc/docker/daemon.json`: ротация логов (`max-size`, `max-file`) и
  `live-restore`.
- `admin_user` добавляется в группу `docker` при
  `docker_add_admin_to_group=true` (нужен новый логин).

### Sudo

- Debian/Ubuntu проверяется членство в группе `sudo`, RHEL — в `wheel`.
- Если пользователя нет, он создаётся с домашней директорией и `/bin/bash`.
- При `admin_user_sudo_nopasswd=true` создаётся
  `/etc/sudoers.d/90-<user>` с `NOPASSWD:ALL`; файл проверяется
  `visudo -cf`.
- Для `admin_user=root` членство в группе не требуется.

## Проверка

`verify.sh` определяет ОС и проверяет:

- установленные пакеты (apt/rpm; `curl-minimal` засчитывается как `curl`);
- случайный порт, эффективный конфиг `sshd -T`, фактический listen через `ss`;
- наличие ключа, права `600`, владельца и наличие ключа в `authorized_keys`;
- отключение паролей, пустых паролей, agent forwarding и root-логина;
- `AddressFamily inet`, `LogLevel VERBOSE`, `AllowUsers`;
- firewall: UFW или firewalld (active, новый порт разрешён, 22 закрыт,
  `firewall_allowed_ports` открыты);
- active `crowdsec` и `crowdsec-firewall-bouncer`, LAPI, метрики, коллекцию
  `sshd`, парсер whitelists, зарегистрированный bouncer и его режим;
- `rsyslog` и `/var/log/auth.log` на Debian/Ubuntu;
- автообновления (unattended-upgrades / dnf-automatic);
- конфиг BBR, IPv6 и sysctl hardening (runtime-значения — на не-контейнере);
- конфиг zram и активный сервис (на не-контейнере);
- Docker CE service, ответ daemon, `daemon.json` и доступ к сокету;
- членство в sudo/wheel и работу `sudo -n`;
- отсутствие неожиданных внешних TCP-listener'ов: разрешены только SSH-порт,
  loopback и `firewall_allowed_ports`;
- необходимость перезагрузки.

Запуск:

```bash
./verify.sh
```

При успехе скрипт завершается с кодом 0 и печатает `passed/failed/skipped`.

## Тесты и линтеры

Molecule-сценарий поднимает три контейнера и для каждого прогоняет
`converge → idempotence → verify`. Повторный прогон обязан дать `changed=0`.

```bash
pip install ansible-core ansible-lint yamllint molecule 'molecule-plugins[docker]'
ansible-galaxy collection install -r requirements.yml
ansible-galaxy collection install -r molecule/default/requirements.yml

yamllint .
ansible-lint

# по одной платформе
molecule test -p debian13
molecule test -p ubuntu2404
molecule test -p rockylinux9
```

Платформы: `geerlingguy/docker-debian13-ansible`,
`geerlingguy/docker-ubuntu2404-ansible`,
`geerlingguy/docker-rockylinux9-ansible` (AlmaLinux 9 покрывается тем же
RHEL-семейством). Для systemd контейнеры запускаются с
`/lib/systemd/systemd` (RHEL — `/usr/lib/systemd/systemd`), `privileged`,
`cgroupns_mode: host` и монтированием `/sys/fs/cgroup`.

GitHub Actions (`.github/workflows/ci.yml`) запускает `yamllint`,
`ansible-lint` и матрицу Molecule для всех трёх платформ.

## Безопасность и ограничения

- Порт 22 закрывается, вход по паролю выключается, остаётся только ключ.
  Плейбук не отключает пароли, пока не убедится, что ключ реально добавлен.
- Храните приватный ключ с правами `600` и не коммитьте `artifacts/`.
- Docker публикует порты через свои iptables/nftables-правила в обход
  UFW/firewalld. Если контейнеры публикуют порты, ограничивайте их отдельно
  (bind на `127.0.0.1` или правила Docker/host).
- `NOPASSWD` для администратора удобен для key-only сервера, но это осознанный
  компромисс. Отключается через `-e admin_user_sudo_nopasswd=false`.
- `live-restore` сохраняет контейнеры при перезапуске Docker daemon, но не
  заменяет собой мониторинг и обновление контейнеров.
- Плейбук не управляет SELinux-политиками приложений и не открывает порты
  автоматически для контейнеров — используйте `firewall_allowed_ports`.
