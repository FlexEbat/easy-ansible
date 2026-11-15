# easy-ansible

Ansible-плейбук, который за один запуск приводит свежий Debian/Ubuntu или
RHEL-совместимый Linux к безопасному и удобному состоянию: обновления,
firewall, защита от перебора (CrowdSec), Docker, сетевая и ядерная
оптимизация. Подходит и для **домашнего компьютера**, и для **сервера (VPS)**;
запускается на самой машине или удалённо.

- [Что делает](#что-делает)
- [Поддерживаемые ОС](#поддерживаемые-ос)
- [Перед запуском](#перед-запуском)
- [Запуск на домашнем компьютере](#запуск-на-домашнем-компьютере-или-домашнем-сервере)
- [Запуск на сервере (VPS)](#запуск-на-сервере-vps)
- [Повторный запуск и изменение настроек](#повторный-запуск-и-изменение-настроек)
- [Проверка результата](#проверка-результата)
- [Переменные](#переменные) и [что именно настраивается](#что-именно-настраивается)
- [Если что-то пошло не так](#если-что-то-пошло-не-так)
- [Безопасность и ограничения](#безопасность-и-ограничения)

## Что делает

1. Определяет ОС и обновляет все пакеты (`apt dist-upgrade` или `dnf upgrade`).
2. Ставит нужные программы: `sudo`, `curl`, `wget`, `git`, `mtr`, `trippy`,
   `chrony`, `zram`, `CrowdSec` и официальный `Docker CE`; включает автообновления.
3. Включает firewall (UFW или firewalld): входящие закрыты, открыт SSH
   (`22/tcp`) и порты, которые вы укажете.
4. Настраивает CrowdSec с firewall bouncer: перебор паролей и сканирование
   приводят к бану адреса. Ваши адреса можно внести в whitelist.
5. Включает BBR, защитные сетевые sysctl, zram-swap, лимит журнала `journald`;
   IPv6 по умолчанию отключается (можно оставить).
6. Проверяет `admin_user` в группе sudo/wheel; если пользователя нет — создаёт
   его (с паролем и/или SSH-ключами, если они заданы).
7. По желанию (`ssh_harden`) закрывает вход в SSH по паролю.
8. Сообщает, нужна ли перезагрузка, и сохраняет итоги в
   `/etc/ansible-setup-summary.json`; `verify.sh` проверяет результат.

Повторный запуск безопасен: плейбук идемпотентен, повторный прогон ничего
не меняет, если настройки не менялись (кроме установки новых обновлений пакетов).

## Поддерживаемые ОС

| Семейство | Дистрибутивы | Пакеты | Firewall | sudo-группа | zram |
|---|---|---|---|---|---|
| Debian | Debian 13+, Ubuntu 24.04+ | `apt` | `ufw` | `sudo` | `zram-tools` |
| RHEL | RHEL 8/9, AlmaLinux, Rocky, CentOS Stream, Oracle Linux | `dnf` | `firewalld` | `wheel` | `zram-generator` |

Debian 12 и Ubuntu 22.04 больше не поддерживаются: для них нет актуальных
пакетов CrowdSec/Docker в нужной конфигурации. Плейбук проверяет ОС в начале и
останавливается с понятной ошибкой на неподдерживаемой системе.

## Перед запуском

1. **Доступ к консоли.** Для сервера — панель VPS/IPMI, для домашней машины —
   монитор или второй терминал. Плейбук включает firewall, и ошибка в портах
   может закрыть доступ по сети.
2. **Откройте нужные порты заранее** через `firewall_allowed_ports` (например,
   80/443 для веба, `445` из локальной сети для Samba). Всё остальное входящее
   будет закрыто, кроме SSH.
3. **Первый запуск долгий:** сначала обновляются все пакеты, ставится Docker.
   Не прерывайте его; после завершения при необходимости перезагрузитесь.
4. **Свои настройки — в файле `vars.local.yml`:**

   ```bash
   cp vars.example.yml vars.local.yml
   nano vars.local.yml      # раскомментируйте и поправьте нужное
   ```

   Файл в `.gitignore` и не попадёт в репозиторий. Подключается ключом
   `-e @vars.local.yml`.

## Запуск на домашнем компьютере или домашнем сервере

Подходит для ноутбука/десктопа/мини-ПК с Debian, Ubuntu, AlmaLinux, Rocky Linux
и т. п., запускается **прямо на этой машине** под вашим пользователем с `sudo`.

```bash
# 1. git (если ещё нет)
sudo apt-get update && sudo apt-get install -y git     # Debian/Ubuntu
sudo dnf install -y git                                 # RHEL-семейство

# 2. код
git clone https://github.com/FlexEbat/easy-ansible.git
cd easy-ansible

# 3. свои настройки (см. подсказки ниже)
cp vars.example.yml vars.local.yml
nano vars.local.yml

# 4. запуск; Ansible и нужные коллекции run.sh поставит сам
sudo ./run.sh -e admin_user="$USER" -e @vars.local.yml

# 5. проверка
sudo ./verify.sh
```

Что заполнить в `vars.local.yml` для дома:

```yaml
crowdsec_whitelist_cidrs: ["192.168.1.0/24"]   # ваша домашняя сеть: её CrowdSec не банит
firewall_allowed_ports:                        # то, к чему должны подключаться из дома
  - {port: 445, proto: tcp, from: 192.168.1.0/24}   # например, Samba
docker_default_bind_ip: 127.0.0.1              # порты контейнеров только для самой машины
# disable_ipv6: false                          # раскомментируйте, если IPv6 нужен
```

Что учесть:

- **`-e admin_user="$USER"` обязателен.** Под `sudo` Ansible считает, что он
  `root`; без этого проверка sudo и группа `docker` относились бы к `root`.
  Пользователь уже есть в системе, пароль и ключи задавать не нужно.
- **Firewall закроет входящие подключения из локальной сети** (Samba, Plex,
  Syncthing, KDE Connect и т. п.). Откройте нужное в `firewall_allowed_ports`
  с ограничением `from: ваша сеть`.
- **mDNS/LLMNR в `systemd-resolved` отключаются.** Обнаружение `*.local` через
  resolved перестанет работать (Avahi это не затрагивает).
- **Docker обходит firewall:** `docker_default_bind_ip: 127.0.0.1` делает порты
  контейнеров доступными только локально; наружу публикуйте явно
  (`"192.168.1.10:8080:80"` в compose).
- **Перезагрузитесь после первого запуска**, если в итогах
  `Reboot required: True`: новое ядро и отключение IPv6 вступают в силу только
  после этого.
- **`verify.sh` на десктопе может показать FAIL «unexpected external TCP
  listeners»** — это значит, что какая-то служба слушает на всех интерфейсах
  (`sudo ss -ltnp` покажет, какая). Закройте её или откройте порт осознанно.

## Запуск на сервере (VPS)

Рекомендуемый порядок для нового сервера: **сначала настроить и зайти по
ключу, потом закрыть пароли**. Так вы не потеряете доступ.

### Вариант А. Прямо на сервере (через консоль или SSH под root)

```bash
# 1. git
apt-get update && apt-get install -y git               # Debian/Ubuntu
# dnf install -y git                                    # RHEL-семейство

# 2. код и настройки
git clone https://github.com/FlexEbat/easy-ansible.git
cd easy-ansible
cp vars.example.yml vars.local.yml
nano vars.local.yml

# 3. запуск
./run.sh -e @vars.local.yml

# 4. проверка
./verify.sh
```

Минимальный `vars.local.yml` для сервера:

```yaml
admin_user: admin                         # создаётся, если его нет
admin_user_authorized_keys:
  - ssh-ed25519 AAAA... me@laptop         # ваш публичный ключ (cat ~/.ssh/id_ed25519.pub)
admin_user_sudo_nopasswd: true            # у key-only пользователя нет пароля для sudo
crowdsec_whitelist_ips: ["203.0.113.5"]   # ваш IP для управления, чтобы не забанили
crowdsec_whitelist_cidrs: []
firewall_allowed_ports:
  - {port: 80}
  - {port: 443}
docker_default_bind_ip: 127.0.0.1         # порты контейнеров не торчат в интернет
# auto_reboot: true                       # перезагружаться самому после обновлений ядра
```

> Без `admin_user_authorized_keys` (или `admin_user_password_hash`) новый
> пользователь создаётся **заблокированным** и войти им нельзя. А без
> `admin_user_sudo_nopasswd: true` пользователь без пароля не сможет выполнить
> `sudo`. Ключ и пароль/`NOPASSWD` нужны вместе.

**Закройте вход по паролю** (второй запуск). Сначала проверьте вход по ключу в
**новой** терминальной сессии, текущую не закрывайте:

```bash
ssh admin@203.0.113.10        # должно пустить по ключу, без пароля
```

Затем на сервере:

```bash
./run.sh -e @vars.local.yml \
  -e ssh_harden=true -e ssh_password_auth=false -e ssh_permit_root_login=no
```

Плейбук откажется отключать пароли, если у `admin_user` нет ключей в
`authorized_keys`. Настройка применяется через `reload`, текущие сессии не
разрываются. Подробности — в разделе «SSH».

### Вариант Б. Удалённо, с ноутбука

На ноутбуке нужен Ansible (`pip install ansible-core` или пакет дистрибутива) и
SSH-доступ к серверу с `sudo`.

```bash
git clone https://github.com/FlexEbat/easy-ansible.git
cd easy-ansible
ansible-galaxy collection install -r requirements.yml
cp vars.example.yml vars.local.yml && nano vars.local.yml

# собственный inventory
cat > prod.ini <<'EOF'
[servers]
prod-01 ansible_host=203.0.113.10 ansible_user=admin
EOF

ansible-playbook -i prod.ini site.yml -K -e @vars.local.yml

# проверка на сервере
scp verify.sh admin@203.0.113.10:/tmp/
ssh -t admin@203.0.113.10 'sudo bash /tmp/verify.sh'
```

- **Используйте свой `prod.ini`, а не `inventory.ini`.** В `inventory.ini` есть
  группа `[local]`, а в плейбуке `hosts: all`: запуск с ним настроил бы заодно и
  ваш ноутбук.
- `-K` запрашивает пароль `sudo` для `ansible_user` (не нужен при
  `admin_user_sudo_nopasswd: true`).
- `admin_user` по умолчанию — это `ansible_user` (пользователь, под которым
  Ansible заходит на сервер), а не `$USER` ноутбука.
- Дополнительно проверьте firewall **у хостера** (облачные security groups):
  порты должны быть открыты и там.

## Повторный запуск и изменение настроек

Измените `vars.local.yml` и запустите ту же команду ещё раз: применятся только
различия. Примеры:

| Что нужно | Как |
|---|---|
| открыть порт | добавить запись в `firewall_allowed_ports` |
| оставить IPv6 | `disable_ipv6: false` (конфиги удалятся, IPv6 вернётся после перезагрузки) |
| выключить автообновления | `auto_updates_enabled: false` |
| вернуть вход по паролю | `ssh_harden: false` (drop-in удаляется) |
| не ставить `trippy`, `chrony` | `base_install_trippy: false`, `base_time_sync: false` |
| посмотреть, что получилось | `sudo ./verify.sh` и `cat /etc/ansible-setup-summary.json` |

Полный список переменных — в разделе «Переменные».

### Тест в LXC-контейнере

Для отладки плейбука (не для реальной защиты):

```bash
tar -C "$HOME" -czf - easy-ansible | lxc exec linux-lab -- bash -lc 'tar -xzf - -C /root'
lxc exec linux-lab -- bash -lc 'cd /root/easy-ansible && ./run.sh -e admin_user=labadmin'
lxc exec linux-lab -- bash -lc 'cd /root/easy-ansible && ./verify.sh'
```

В контейнере kernel-настройки (BBR, sysctl, zram, параметры загрузки) только
записываются, но не применяются: ядром управляет хост.

## Проверка результата

### Итоги запуска

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
  "firewall_allowed_ports": ["80/tcp", "443/tcp"],
  "firewall_backend": "ufw",
  "os_family": "Debian",
  "reboot_required": false,
  "ssh_harden": false,
  "sudo_group": "sudo"
}
```

(показана часть полей). Порты записываются как `порт/протокол`. Плейбук также
печатает основные значения в задаче `Show setup summary`. `verify.sh`
сверяет систему именно с этим файлом.

### Скрипт verify.sh

`verify.sh` определяет ОС и проверяет:

- установленные пакеты (apt/rpm; `curl-minimal` засчитывается как `curl`);
- SSH: `sshd` слушает порт 22; при `ssh_harden=true` проверяются
  `PasswordAuthentication` и `PermitRootLogin` из настроек плейбука (вход по
  паролю сам по себе не требуется и не запрещается);
- firewall: UFW или firewalld (active, порт 22 разрешён — `LIMIT` при
  `firewall_ssh_rate_limit`, `firewall_allowed_ports` вместе с протоколом);
- `chrony`, лимит `journald`;
- active `crowdsec` и `crowdsec-firewall-bouncer`, LAPI, метрики, коллекцию
  `sshd`, парсер whitelists, зарегистрированный bouncer и его режим;
- `rsyslog` и `/var/log/auth.log` на Debian/Ubuntu;
- автообновления (unattended-upgrades / dnf-automatic);
- конфиг BBR, IPv6 и sysctl hardening (runtime-значения — на не-контейнере);
- конфиг zram и активный сервис (на не-контейнере);
- Docker CE service, ответ daemon, `daemon.json` и доступ к сокету;
- членство в sudo/wheel; `sudo -n` — только при `admin_user_sudo_nopasswd=true`
  (иначе проверяется, что файл sudoers не создан);
- отсутствие неожиданных внешних TCP-listener'ов: разрешены только порт 22,
  loopback и `firewall_allowed_ports`;
- необходимость перезагрузки.

Запуск (нужны root-права — скрипт читает `sshd -T`, `ufw status` и файлы,
доступные только root):

```bash
sudo ./verify.sh
```

При успехе скрипт завершается с кодом 0 и печатает `passed/failed/skipped`.

## Переменные

Свои значения удобно держать в `vars.local.yml` (шаблон — `vars.example.yml`) и
подключать ключом `-e @vars.local.yml`.

Общие переменные (`admin_user*`, `firewall_allowed_ports`, определение ОС)
лежат в `group_vars/all.yml`. Всё, что относится к одной роли, — в
`roles/<роль>/defaults/main.yml`; любую переменную можно переопределить в
`group_vars`, inventory или через `-e`.

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `admin_user` | `ansible_user` | пользователь, которого проверяем/добавляем в sudo/wheel |
| `admin_user_password_hash` | `""` | хэш пароля для **нового** пользователя (`mkpasswd --method=sha-512`); пароль существующего не меняется |
| `admin_user_authorized_keys` | `[]` | публичные SSH-ключи пользователя |
| `admin_user_sudo_nopasswd` | `false` | беспарольный sudo (включайте только для key-only аккаунта) |
| `ssh_harden` | `false` | включить drop-in `00-ansible-hardening.conf` для sshd |
| `ssh_password_auth` | `true` | вход по паролю (при `ssh_harden`); `false` = только ключи |
| `ssh_permit_root_login` | `prohibit-password` | `no` / `prohibit-password` / `yes` |
| `firewall_allowed_ports` | `[]` | дополнительные порты (`port`, `proto`, `from`) |
| `firewall_ssh_rate_limit` | `true` | UFW: `limit` вместо `allow` для 22/tcp |
| `auto_updates_enabled` | `true` | unattended-upgrades / dnf-automatic |
| `auto_reboot` / `auto_reboot_time` | `false` / `04:00` | автоперезагрузка после обновлений (время — только Debian/Ubuntu) |
| `base_time_sync` | `true` | установить и включить `chrony` (не в контейнерах) |
| `base_journald_max_use` | `500M` | `SystemMaxUse` для journald; пустая строка — не трогать |
| `base_install_trippy` | `true` | ставить `trippy` (`false` — только `mtr`) |
| `disable_ipv6` | `true` | отключить IPv6; `false` убирает конфиги (эффект после перезагрузки) |
| `kernel_rp_filter` | `2` | `rp_filter`: 2 loose (безопасно с VPN/Docker), 1 strict, 0 off |
| `kernel_log_martians` | `0` | логировать martian-пакеты |
| `zram_percent` / `zram_algorithm` / `zram_priority` | `25` / `zstd` / `100` | параметры zram |
| `crowdsec_whitelist_ips` | `[]` | IP, которые CrowdSec никогда не заблокирует |
| `crowdsec_whitelist_cidrs` | `[]` | подсети-исключения (в `inventory.ini` для лаборатории задан `192.168.1.0/24`) |
| `docker_service_enabled` | `true` | включает/выключает Docker |
| `docker_add_admin_to_group` | `true` | добавить `admin_user` в группу `docker` |
| `docker_default_bind_ip` | `""` | адрес по умолчанию для опубликованных портов; `127.0.0.1` закрывает их от интернета |
| `docker_no_new_privileges` | `false` | `no-new-privileges` по умолчанию для всех контейнеров |
| `docker_log_max_size` / `docker_log_max_file` | `10m` / `3` | ротация логов Docker |
| `docker_live_restore` | `true` | не останавливать контейнеры при рестарте daemon |

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
- `trippy` (`roles/base/tasks/trippy.yml`, общий для обоих семейств) ставится
  из репозитория дистрибутива, если доступен; иначе загружается upstream-артефакт
  с проверкой SHA-256 (`.deb`/RPM для x86_64, tarball для aarch64). На других
  архитектурах пропускается. Отключается `base_install_trippy=false`.
- `chrony` (синхронизация времени; не в контейнерах) и лимит `journald`
  (`/etc/systemd/journald.conf.d/99-ansible.conf`).
- `auto_reboot=true` включает автоперезагрузку после обновлений
  (`Automatic-Reboot` в unattended-upgrades; `reboot = when-needed` в
  dnf-automatic — на старых dnf-automatic опция игнорируется).
- В конце проверяется `/var/run/reboot-required` (Debian/Ubuntu) или
  `needs-restarting -r` (RHEL), результат попадает в summary и выводится
  предупреждение.

### SSH

По умолчанию плейбук не изменяет конфигурацию `sshd`: порт 22, вход по логину и
паролю включён. Роль `base` гарантирует, что `openssh-server` установлен, а
firewall открывает `22/tcp` (UFW — с `limit`: не более 6 новых подключений за
30 секунд с одного адреса).

Опционально (`-e ssh_harden=true`) роль `ssh` пишет drop-in
`/etc/ssh/sshd_config.d/00-ansible-hardening.conf` (читается первым, поэтому
перекрывает, например, файлы cloud-init): `PermitRootLogin`, `PubkeyAuthentication`,
`PasswordAuthentication`, `MaxAuthTries`, `X11Forwarding`. Порт SSH не меняется.
Конфигурация проверяется `sshd -t`, применяется через `reload`
(текущие сессии не разрываются). Для отключения паролей:

```bash
ansible-playbook site.yml -e ssh_harden=true -e ssh_password_auth=false \
  -e '{"admin_user_authorized_keys": ["ssh-ed25519 AAAA... me@laptop"]}'
```

Плейбук откажется отключать пароли, если у `admin_user` нет непустого
`authorized_keys` (защита от потери доступа). `ssh_harden=false` удаляет drop-in.

### Firewall

- Debian/Ubuntu: UFW, default incoming `deny`, outgoing `allow`, routed `deny`.
  `22/tcp` разрешён явно (SSH на порту по умолчанию).
- RHEL: firewalld, зона по умолчанию или `firewalld_zone`; включается сервис
  `ssh`.
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
  `crowdsec_whitelist_ips` / `crowdsec_whitelist_cidrs`. Сеть хоста целиком
  **не** добавляется: на VPS это подсеть провайдера.
- На Debian 13 ставится и включается `rsyslog`, иначе CrowdSec не видит
  `/var/log/auth.log`.
- Bouncer регистрируется автоматически пакетом; если пакет оставил
  placeholder-ключ и `/var/lib/crowdsec/pending-registration`, плейбук создаёт
  bouncer через `cscli bouncers add` и удаляет маркер.
- `cscli metrics` проверяется с fallback на Prometheus-эндпоинт
  `127.0.0.1:6060`, потому что в CrowdSec 1.4.6 на Ubuntu метрики могут падать
  с ошибкой protobuf.

### BBR, IPv6 и sysctl hardening

- Файлы `/etc/sysctl.d/*.conf` ведутся модулем `ansible.posix.sysctl`
  (формат `ключ=значение`); значения применяет handler `sysctl -p`, только при
  изменении файла и не внутри контейнеров.
- BBR: `/etc/sysctl.d/99-bbr.conf` с `fq` и `bbr`; на реальном хосте
  загружаются модули `tcp_bbr` и `sch_fq`.
- IPv6 (`disable_ipv6`, по умолчанию `true`): `/etc/sysctl.d/99-disable-ipv6.conf`
  и `ipv6.disable=1` в командной строке ядра (Debian/Ubuntu — drop-in
  `/etc/default/grub.d/99-disable-ipv6.cfg` + `update-grub`, RHEL — `grubby`;
  без `grubby` параметр дописывается к существующему `GRUB_CMDLINE_LINUX`).
  При `false` файлы и параметр удаляются.
- Сетевые sysctl (`/etc/sysctl.d/99-hardening.conf`): `rp_filter`
  (по умолчанию loose, `kernel_rp_filter`), SYN cookies, защита от source
  routing и ICMP redirects, `icmp_echo_ignore_broadcasts`,
  `kernel.dmesg_restrict`, `fs.suid_dumpable`. `log_martians` по умолчанию
  выключен. `tcp_syn_retries` больше не задаётся (он влияет только на
  исходящие соединения; из старых конфигов удаляется).
  `net.ipv4.ip_forward` намеренно **не** отключается — он нужен Docker.
- Контейнером считается только гость (`virtualization_role == guest` и тип
  `lxc`/`docker`/`podman`/`containerd`/`systemd-nspawn`): на голом сервере с
  Docker kernel-настройки применяются. В контейнерах конфиги пишутся, но
  применение пропускается — ядром управляет хост (IPv6 применяется, это
  параметр сетевого namespace).

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
- `/etc/docker/daemon.json`: ротация логов (`max-size`, `max-file`),
  `live-restore`; опционально `"ip"` (`docker_default_bind_ip`) и
  `"no-new-privileges"` (`docker_no_new_privileges`).
- `admin_user` добавляется в группу `docker` при
  `docker_add_admin_to_group=true` (нужен новый логин).

### Sudo

- Debian/Ubuntu проверяется членство в группе `sudo`, RHEL — в `wheel`.
- Если пользователя нет, он создаётся с домашней директорией и `/bin/bash`.
  Без `admin_user_password_hash` и `admin_user_authorized_keys` такая учётка
  заблокирована — плейбук выводит предупреждение. Ключи ставятся через
  `authorized_key`, хэш пароля применяется только при создании.
- При `admin_user_sudo_nopasswd=true` создаётся
  `/etc/sudoers.d/90-<user>` с `NOPASSWD:ALL`; файл проверяется
  `visudo -cf`. При `false` (по умолчанию) этот файл удаляется.
- Для `admin_user=root` членство в группе не требуется.

## Если что-то пошло не так

| Симптом | Что делать |
|---|---|
| Потерял SSH-доступ после запуска | зайдите через консоль хостера/монитор; проверьте `sudo ufw status` (или `firewall-cmd --list-all`) и `sudo systemctl status ssh` (на RHEL `sshd`) |
| Меня забанил CrowdSec | `sudo cscli decisions list`, затем `sudo cscli decisions delete --ip ВАШ_IP`; добавьте IP в `crowdsec_whitelist_ips` и запустите плейбук снова |
| Нужный порт недоступен | добавьте его в `firewall_allowed_ports` и запустите плейбук снова; проверьте также firewall хостера |
| Порт контейнера виден из интернета | Docker обходит UFW: задайте `docker_default_bind_ip: 127.0.0.1` или публикуйте порт с явным адресом |
| `sudo` просит пароль, а у пользователя его нет | `admin_user_sudo_nopasswd: true` или задайте `admin_user_password_hash` |
| Новая учётка не может войти | не заданы ни `admin_user_authorized_keys`, ни `admin_user_password_hash`; добавьте и запустите снова |
| `verify.sh`: FAIL «unexpected external TCP listeners» | `sudo ss -ltnp` покажет службу; закройте её или откройте порт осознанно |
| `verify.sh`: BBR/zram не применены | это нормально в контейнере; на VM/железе — перезагрузитесь и проверьте снова |
| Плейбук упал посередине | исправьте причину и запустите снова: он идемпотентен и продолжит с нужного места |

## Структура

```
.
├── ansible.cfg
├── inventory.ini
├── site.yml
├── group_vars/all.yml
├── requirements.yml
├── run.sh
├── vars.example.yml           # шаблон своих настроек (копия: vars.local.yml)
├── verify.sh
├── .ansible-lint
├── .yamllint
├── .github/workflows/ci.yml
├── molecule/default/          # Molecule (Debian 13, Ubuntu 24.04, Rocky 9; Rocky 8 — best effort)
└── roles/                     # у каждой роли свои defaults/main.yml
    ├── base/          # обновление, пакеты, автообновления, chrony, journald, trippy
    ├── admin_user/    # admin_user, пароль/ключи, группа sudo/wheel, sudoers
    ├── ssh/           # опциональная настройка sshd (ssh_harden, по умолчанию выключена)
    ├── firewall/      # UFW или firewalld (SSH на порту 22 разрешён)
    ├── crowdsec/      # сервис, LAPI, collections, bouncer, whitelist
    ├── kernel/        # BBR, IPv6, sysctl hardening, zram
    └── docker/        # официальный Docker CE и daemon.json
```

## Тесты и линтеры

Molecule-сценарий поднимает контейнеры (Debian 13, Ubuntu 24.04, Rocky 9 и экспериментально Rocky 8) и для каждого прогоняет
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
molecule test -p rockylinux8   # best effort

shellcheck verify.sh run.sh
```

Платформы: `geerlingguy/docker-debian13-ansible`,
`geerlingguy/docker-ubuntu2404-ansible`,
`geerlingguy/docker-rockylinux9-ansible` (AlmaLinux 9 покрывается тем же
RHEL-семейством). Для systemd контейнеры запускаются с
`/lib/systemd/systemd` (RHEL — `/usr/lib/systemd/systemd`), `privileged`,
`cgroupns_mode: host` и монтированием `/sys/fs/cgroup`.

GitHub Actions (`.github/workflows/ci.yml`) запускает `yamllint`,
`ansible-lint`, `shellcheck` и матрицу Molecule. Rocky 8 в CI помечен как
`continue-on-error`: RHEL 8 заявлен как поддерживаемый, но не гарантирован
автотестами (системный Python 3.6 слишком стар для свежих `ansible-core`).

## Безопасность и ограничения

- SSH по умолчанию остаётся в конфигурации дистрибутива: порт 22, вход по
  паролю включён (UFW ограничивает частоту подключений, CrowdSec банит
  перебор). Для продакшена включите `ssh_harden` с `ssh_password_auth=false`
  и ключами.
- CrowdSec не банит loopback, собственный IP хоста и адреса из
  `crowdsec_whitelist_ips` / `crowdsec_whitelist_cidrs`. Добавьте сюда свои
  management-адреса, чтобы опечатки в пароле не привели к блокировке.
- Docker публикует порты через свои iptables/nftables-правила в обход
  UFW/firewalld. Чтобы опубликованные порты не были видны из интернета по
  умолчанию, задайте `docker_default_bind_ip: 127.0.0.1` и открывайте нужное
  явно (`"0.0.0.0:443:443"` в compose); иначе ограничивайте их правилами
  `DOCKER-USER`.
- `NOPASSWD` выключен по умолчанию; включайте только для аккаунта, который
  входит по ключу.
- `live-restore` сохраняет контейнеры при перезапуске Docker daemon, но не
  заменяет собой мониторинг и обновление контейнеров.
- Плейбук не управляет SELinux-политиками приложений и не открывает порты
  автоматически для контейнеров — используйте `firewall_allowed_ports`.
