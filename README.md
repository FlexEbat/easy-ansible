# Hardening playbook для Debian/Ubuntu и RHEL

Ansible-плейбук приводит чистый сервер (или LXC-контейнер) к состоянию:

1. Определяет ОС и обновляет все пакеты (`apt dist-upgrade` или `dnf upgrade`).
2. Переносит SSH на случайный порт, закрывает порт 22, запрещает вход по
   паролю, генерирует ключ `ed25519` и показывает, где он лежит.
3. Устанавливает `sudo`, `curl`, `wget`, `mtr`, `trippy`, `git`, `zram`,
   `CrowdSec` и официальный `Docker CE`.
4. Настраивает firewall, CrowdSec (+ firewall bouncer), BBR, отключение IPv6
   и zram.
5. Проверяет, что `$USER` (или `admin_user`) есть в группе администраторов;
   если нет — добавляет и настраивает беспарольный sudo.

## Поддерживаемые ОС

| Семейство | Дистрибутивы | Пакеты | Firewall | sudo-группа | zram |
|---|---|---|---|---|---|
| Debian | Debian 12/13, Ubuntu 22.04/24.04 | `apt` | `ufw` | `sudo` | `zram-tools` |
| RHEL | RHEL 8/9, AlmaLinux, Rocky, CentOS Stream, Oracle Linux | `dnf` | `firewalld` | `wheel` | `zram-generator` |

Плейбук проверяет ОС в начале и останавливается с понятной ошибкой на
неподдерживаемой системе.

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
└── roles/
    ├── base/          # обновление и пакеты (apt/dnf, EPEL, trippy)
    ├── admin_user/    # $USER, группа sudo/wheel, sudoers
    ├── ssh/           # случайный порт, sshd_config, ключ, SELinux
    ├── firewall/      # UFW или firewalld
    ├── crowdsec/      # сервис, LAPI, collections, bouncer
    ├── kernel/        # BBR, IPv6, zram (zram-tools / zram-generator)
    └── docker/        # официальный Docker CE
```

## Быстрый запуск (LXC linux-lab)

Из хоста:

```bash
# скопировать проект в контейнер
tar -C "$HOME" -czf - ansible | lxc exec linux-lab -- bash -lc 'tar -xzf - -C /root'

# запустить (admin_user можно не указывать — возьмётся $USER)
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

## Где лежит ключ и порт

После запуска на сервере есть файл `/etc/ansible-setup-summary.json`:

```json
{
  "admin_home": "/home/labadmin",
  "admin_user": "labadmin",
  "distribution": "Debian",
  "distribution_version": "13.1",
  "firewall_backend": "ufw",
  "os_family": "Debian",
  "ssh_allowed_from": ["any"],
  "ssh_port": 22911,
  "ssh_port_file": "/etc/ansible-ssh-port",
  "ssh_private_key": "/home/labadmin/.ssh/id_ed25519",
  "ssh_public_key": "/home/labadmin/.ssh/id_ed25519.pub",
  "sudo_group": "sudo"
}
```

Плейбук также печатает эти пути в задаче `Show setup summary`.
Порт сохраняется в `/etc/ansible-ssh-port`, поэтому повторные запуски не меняют
его и остаются идемпотентными.

> Для удалённого сервера после первого запуска SSH уже слушает новый порт.
> Добавьте его в inventory для следующих запусков:
> `prod-01 ansible_port=<порт из /etc/ansible-ssh-port>`.
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
| `admin_user` | `$SUDO_USER` → `$USER` | пользователь, которого проверяем/добавляем в sudo/wheel |
| `admin_user_sudo_nopasswd` | `true` | беспарольный sudo для key-only пользователя |
| `ssh_port_min` / `ssh_port_max` | `20000` / `32000` | диапазон случайного порта |
| `ssh_password_authentication` | `false` | вход по паролю |
| `ssh_permit_root_login` | `prohibit-password` | root только по ключу |
| `ssh_allowed_cidrs` | `[]` | `[]` = новый порт открыт всем; можно указать подсети |
| `ssh_key_fetch` | `false` | копировать приватный ключ на control node |
| `zram_percent` | `25` | сколько RAM отдать под zram |
| `zram_algorithm` | `zstd` | алгоритм сжатия zram |
| `docker_service_enabled` | `true` | включает/выключает Docker |

`admin_user` по умолчанию — локальный `$SUDO_USER`/`$USER` (как в задании).
При управлении удалённым сервером обычно имеет смысл явно указать аккаунт,
под которым вы подключаетесь: `-e admin_user=admin`.

Пример ограничения SSH только локальными сетями:

```bash
ansible-playbook site.yml \
  -e admin_user=alice \
  -e '{"ssh_allowed_cidrs":["10.0.0.0/8","192.168.0.0/16"]}'
```

## Что именно настраивается

**SSH**

- `Port <random>` в `/etc/ssh/sshd_config.d/00-ansible-hardening.conf`.
- На RHEL добавляется `Include /etc/ssh/sshd_config.d/*.conf`, если его нет.
- Все остальные `Port`-директивы в основном конфиге и drop-in файлах
  комментируются, чтобы sshd не продолжал слушать 22.
- `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PubkeyAuthentication yes`, `PermitRootLogin prohibit-password`.
- Генерируется `ed25519` ключ в домашней директории `admin_user`, публичная
  часть добавляется в `authorized_keys`.
- Конфиг проверяется через `sshd -t` до перезапуска.
- На RHEL с включённым SELinux новый порт добавляется в тип `ssh_port_t`
  через `semanage`/`community.general.seport`.
- Если после предыдущего неудачного запуска sshd остался на старом порту,
  финальная задача обнаружит это через `ss` и перезапустит сервис.

**Firewall**

- Debian/Ubuntu: UFW. default incoming `deny`, outgoing `allow`,
  routed `deny`; новый SSH-порт разрешён (для `ssh_allowed_cidrs` или для
  всех); порт `22/tcp` явно запрещён; UFW включается.
- RHEL: firewalld. Новый SSH-порт открывается в зоне по умолчанию (обычно
  `public`; можно задать `firewalld_zone`); сервис `ssh` и порт `22/tcp`
  удаляются из зоны. При заданных `ssh_allowed_cidrs` вместо открытого порта
  создаются rich rules с ограничением по source. Остальные сервисы зоны
  (например, `cockpit`) плейбук не трогает.

**CrowdSec**

- Debian/Ubuntu: ставятся `crowdsec` и `crowdsec-firewall-bouncer` из
  репозитория дистрибутива.
- RHEL: официальный репозиторий CrowdSec на packagecloud
  (`https://packagecloud.io/crowdsec/crowdsec/el/$releasever/$basearch`,
  с проверкой GPG), пакеты `crowdsec` и
  `crowdsec-firewall-bouncer-nftables`.
- Сервисы включаются и запускаются; плейбук ждёт Local API.
- Проверяются/доустанавливаются коллекции `crowdsecurity/linux` и
  `crowdsecurity/sshd`.
- Bouncer обычно регистрируется пакетом автоматически. Если этого не
  произошло, плейбук создаёт bouncer через `cscli bouncers add` и записывает
  ключ в `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local`.

**BBR**

- пишется `/etc/sysctl.d/99-bbr.conf`:
  `net.core.default_qdisc = fq` и
  `net.ipv4.tcp_congestion_control = bbr`;
- на реальном хосте/VM загружаются модули `tcp_bbr`/`sch_fq` и применяется
  `sysctl -p`.

**IPv6**

- пишется `/etc/sysctl.d/99-disable-ipv6.conf` и применяется через `sysctl -p`;
- Debian/Ubuntu: создаётся GRUB drop-in
  `/etc/default/grub.d/99-disable-ipv6.cfg` с `ipv6.disable=1`;
  если `update-grub` доступен, GRUB перегенерируется.
- RHEL: `grubby --update-kernel=ALL --args="ipv6.disable=1"` (или
  `/etc/default/grub` + `grub2-mkconfig`, если `grubby` нет).
- В задании было `/etc/defaut/boot`; это трактуется как настройка загрузчика
  (`/etc/default/grub` и/или `grubby`) плюс sysctl, чтобы IPv6 отключался
  сразу, без ожидания reboot.

**zram**

- Debian/Ubuntu: `/etc/default/zramswap` — `ALGO=zstd`, `PERCENT=25`,
  `PRIORITY=100`; сервис `zramswap` включается и запускается, если доступен
  модуль/устройство zram.
- RHEL: `/etc/systemd/zram-generator.conf` — `[zram0]`,
  `zram-size = ram * 25 / 100`, `compression-algorithm = zstd`,
  `swap-priority = 100`; запускается `systemd-zram-setup@zram0.service`.

**Docker (официальный Docker CE, не `docker.io`)**

- Debian:
  - `https://download.docker.com/linux/debian/gpg` →
    `/etc/apt/keyrings/docker.asc`;
  - `/etc/apt/sources.list.d/docker.sources` с `VERSION_CODENAME`,
    `dpkg --print-architecture` и `Signed-By`.
- Ubuntu: то же, но `https://download.docker.com/linux/ubuntu/gpg` и suite
  `${UBUNTU_CODENAME:-$VERSION_CODENAME}`.
- RHEL: `dnf install dnf-plugins-core`, затем
  `dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo`.
- На всех системах удаляются конфликтующие пакеты дистрибутива
  (`docker.io`, `podman`, `runc` и т. п.) и ставятся
  `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`.

**Sudo**

- Debian/Ubuntu проверяется членство `admin_user` в группе `sudo`;
  RHEL — в группе `wheel`.
- если пользователя нет — он создаётся с домашней директорией и `/bin/bash`;
- при `admin_user_sudo_nopasswd=true` создаётся
  `/etc/sudoers.d/90-<user>` с `NOPASSWD:ALL` (файл проверяется `visudo -cf`).

## Проверка

`verify.sh` определяет ОС и проверяет:

- установленные пакеты (apt/rpm);
- случайный порт, эффективный конфиг `sshd -T`, фактический listen через `ss`;
- наличие ключа, права `600`, владельца и наличие ключа в `authorized_keys`;
- отключение паролей и root-логина по паролю;
- firewall: UFW или firewalld (active, новый порт разрешён, 22 закрыт);
- active `crowdsec` и `crowdsec-firewall-bouncer`, LAPI, коллекцию `sshd`,
  зарегистрированный bouncer;
- конфиг BBR (и runtime-значения на не-контейнере);
- IPv6 sysctl + GRUB/grubby;
- конфиг zram и активный сервис (на не-контейнере);
- Docker CE service и ответ daemon;
- членство в sudo/wheel и работу `sudo -n`.

Идемпотентность проверена: повторный запуск даёт `changed=0`.

## Безопасность

- Порт 22 закрывается, вход по паролю выключается, остаётся только ключ.
- Храните приватный ключ с правами `600` и не коммитьте `artifacts/`.
- Docker публикует порты через свои iptables/nftables-правила в обход
  UFW/firewalld. Если контейнеры будут публиковать порты, ограничивайте их
  отдельно (bind на `127.0.0.1` или firewall на уровне Docker/host).
- `NOPASSWD` для администратора удобен для key-only сервера, но это осознанный
  компромисс. Отключается через `-e admin_user_sudo_nopasswd=false`.
