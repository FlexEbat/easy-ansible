# easy-ansible

Ansible-плейбук, который за один запуск приводит свежий Debian/Ubuntu к
безопасному и удобному состоянию (RHEL-совместимые системы — без гарантий,
см. [Поддерживаемые ОС](#поддерживаемые-ос)): обновления,
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
| Debian | Debian 13+, Ubuntu 24.04+ — **поддерживаются** | `apt` | `ufw` | `sudo` | `zram-tools` |
| RHEL | RHEL 8/9, AlmaLinux, Rocky, CentOS Stream, Oracle Linux — **без гарантий** | `dnf` | `firewalld` | `wheel` | `zram-generator` |

Основная поддерживаемая платформа — Debian и Ubuntu. Код для RHEL-семейства в
плейбуке есть, но на нём возможны проблемы: он проверяется в CI только в
контейнерах, а системный `ansible-core` в RHEL 8/9 старый (на RHEL 8 системный Python 3.6 слишком
стар для свежих версий Ansible и коллекций, которые ставятся без закрепления
версий). Используйте его на свой страх и риск.

Проверено на: Debian 13, Ubuntu 24.04 (на виртуальной машине и в контейнере),
Rocky Linux 9 и 8 (в контейнерах). Проверка выполняется в CI
(`.github/workflows/idempotency.yml`): плейбук запускается дважды на каждой
системе, второй запуск не должен ничего менять. Rocky Linux 8 — как и раньше,
без гарантий.

## Перед запуском

1. **Доступ к консоли.** Для сервера — панель VPS/IPMI, для домашней машины —
   монитор или второй терминал. Плейбук включает firewall, и ошибка в портах
   может закрыть доступ по сети.
2. **Первый запуск долгий:** сначала обновляются все пакеты, ставится Docker.
   Не прерывайте его; после завершения при необходимости перезагрузитесь.
3. **Настройки вводить заранее не нужно.** При первом запуске `./run.sh` сам
   задаст несколько вопросов (кто администратор, ваш SSH-ключ, ваши адреса,
   какие порты открыть) и сохранит ответы в `vars.local.yml`. Если этот файл уже
   есть, скрипт просто прочитает его и ничего не спросит.

## Как работает run.sh

```text
./run.sh
   ├─ нет root?             → перезапускается через sudo
   ├─ нет Ansible?          → ставит Ansible и коллекции
   ├─ нет vars.local.yml?   → задаёт вопросы (wizard.sh) и создаёт файл
   ├─ файл есть?            → читает его, вопросов нет
   └─ запускает плейбук с вашими настройками
```

| Команда | Что делает |
|---|---|
| `sudo ./run.sh` | обычный запуск: использует `vars.local.yml` или сначала создаёт его |
| `./run.sh --wizard` | задать вопросы заново (старый файл сохранится как `vars.local.yml.bak`) |
| `./run.sh --wizard-only` | только создать `vars.local.yml` и выйти; root не нужен (например, на ноутбуке перед удалённым запуском) |
| `./run.sh --no-wizard` | никогда не спрашивать: взять `vars.local.yml`, если он есть, иначе значения по умолчанию |
| `./run.sh --harden-ssh` | закрыть вход по паролю и root-вход в SSH (сначала проверьте вход по ключу!) |
| `./run.sh --check` | любые другие параметры уходят в `ansible-playbook`, например `-e admin_user=alice` |

Мастер сам подсказывает значения: ваш IP (если вы подключены по SSH), домашнюю
подсеть, пользователя, вызвавшего `sudo`. Ответы он проверяет (имя пользователя,
IP, CIDR, порты) и записывает файл с правами `600`. Файл можно править руками —
все переменные описаны в `vars.example.yml` и в разделе «Переменные». Файл
`vars.local.yml` в `.gitignore` и в репозиторий не попадёт.

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

# 3. запуск: ответьте на вопросы мастера, Ansible run.sh поставит сам
sudo ./run.sh

# 4. проверка
sudo ./verify.sh
```

На вопросы мастера для дома разумно отвечать так:

| Вопрос | Ответ |
|---|---|
| Что настраиваем | `1` — домашний компьютер |
| Пользователь-администратор | ваш логин (мастер предлагает его сам) |
| Ваши IP / подсети | домашняя сеть (подсказывается автоматически): CrowdSec не будет её банить |
| Порты | те, к которым подключаются из дома (например, `445` для Samba); мастер предложит открыть их только для локальной сети |
| Отключить IPv6 | `n`, если он нужен вашей сети |
| Docker только на localhost | `y` |

Что учесть:

- **Firewall закроет входящие подключения из локальной сети** (Samba, Plex,
  Syncthing, KDE Connect и т. п.). Откройте нужное в вопросе про порты; для
  ограничения источника в `vars.local.yml` есть поле `from`.
- **mDNS/LLMNR в `systemd-resolved` отключаются.** Обнаружение `*.local` через
  resolved перестанет работать (Avahi это не затрагивает).
- **Docker обходит firewall:** ответ `y` на вопрос про localhost делает порты
  контейнеров доступными только самой машине; наружу публикуйте явно
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

# 2. код
git clone https://github.com/FlexEbat/easy-ansible.git
cd easy-ansible

# 3. запуск: мастер задаст вопросы, затем начнётся настройка
./run.sh

# 4. проверка
./verify.sh
```

Ответы для сервера:

| Вопрос | Ответ |
|---|---|
| Что настраиваем | `2` — сервер |
| Пользователь-администратор | например, `admin` (создастся, если его нет) |
| Ключ | ваш публичный ключ (`cat ~/.ssh/id_ed25519.pub` на вашей машине) или путь к `.pub` |
| Ваши IP | ваш адрес для управления (если вы подключены по SSH, мастер подставит его сам) |
| Порты | например, `80 443` |
| Docker только на localhost | `y` |
| Автоперезагрузка | `n` или `y`, если нужны ночные перезагрузки после обновлений ядра |

Если вы дали ключ новому пользователю, мастер включает ему `sudo` без пароля: у
учётки, которая входит по ключу, пароля нет. Без ключа мастер предложит задать
пароль; если не задать ни ключ, ни пароль, пользователь создаётся
**заблокированным**, и войти им нельзя.

**Закройте вход по паролю** (второй запуск). Сначала проверьте вход по ключу в
**новой** терминальной сессии, текущую не закрывайте:

```bash
ssh admin@203.0.113.10        # должно пустить по ключу, без пароля
```

Затем на сервере:

```bash
./run.sh --harden-ssh
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

# настройки: мастер создаст vars.local.yml (root не нужен)
./run.sh --wizard-only

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

- В мастере на ноутбуке отвечайте про **сервер**: логин администратора на
  сервере, ключ, адреса. Подсказки «ваш IP» и «домашняя подсеть» берутся с
  ноутбука, проверьте их.
- **Используйте свой `prod.ini`, а не `inventory.ini`.** В `inventory.ini` есть
  группа `[local]`, а в плейбуке `hosts: all`: запуск с ним настроил бы заодно и
  ваш ноутбук.
- `-K` запрашивает пароль `sudo` для `ansible_user` (не нужен при
  `admin_user_sudo_nopasswd: true`).
- Закрыть вход по паролю: добавьте к команде
  `-e ssh_harden=true -e ssh_password_auth=false -e ssh_permit_root_login=no`.
- Дополнительно проверьте firewall **у хостера** (облачные security groups):
  порты должны быть открыты и там.

## Повторный запуск и изменение настроек

Отредактируйте `vars.local.yml` (или пройдите мастер заново: `./run.sh --wizard`)
и запустите `sudo ./run.sh` ещё раз: применятся только различия. Примеры:

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
lxc exec linux-lab -- bash -lc 'cd /root/easy-ansible && ./run.sh --no-wizard -e admin_user=labadmin'
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

Свои значения хранятся в `vars.local.yml`: его создаёт мастер `./run.sh`, а
вручную можно править по образцу `vars.example.yml`. `run.sh` подключает файл
сам (`-e @vars.local.yml`); при прямом вызове `ansible-playbook` добавьте этот
ключ вручную.

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
| `trippy_version` | `latest` | версия `trippy`: `latest` — всегда последний релиз upstream, либо точная версия |
| `trippy_allow_unverified` | `true` | ставить релизы без известной SHA-256 (`false` — только проверенные) |
| `disable_ipv6` | `true` | отключить IPv6; `false` убирает конфиги (эффект после перезагрузки) |
| `kernel_rp_filter` | `2` | `rp_filter`: 2 loose (безопасно с VPN/Docker), 1 strict, 0 off |
| `kernel_log_martians` | `0` | логировать martian-пакеты |
| `zram_percent` / `zram_algorithm` / `zram_priority` | `25` / `zstd` / `100` | параметры zram |
| `crowdsec_whitelist_ips` | `[]` | IP, которые CrowdSec никогда не заблокирует |
| `crowdsec_whitelist_cidrs` | `[]` | подсети-исключения (например, домашняя сеть) |
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
- `trippy` (`roles/base/tasks/trippy.yml`, общий для обоих семейств): при каждом
  запуске определяется последний релиз upstream (по редиректу
  `github.com/fujiapple852/trippy/releases/latest`, без API) и ставится или
  обновляется до него: `.deb`/RPM на x86_64, tarball на aarch64. Если последний
  релиз определить не удалось или на архитектуре нет upstream-сборки, берётся
  пакет из репозитория дистрибутива (если он там есть); иначе шаг пропускается.
  Upstream не публикует контрольные суммы, поэтому SHA-256 проверяется только для
  версий из `trippy_known_checksums`; для более новых релизов файл скачивается с
  официальной страницы релиза по HTTPS без проверки суммы (запретить это:
  `trippy_allow_unverified: false`). Ошибка установки не прерывает плейбук.
  Отключается `base_install_trippy=false`; закрепить версию — `trippy_version: "0.13.0"`.
- `chrony` (синхронизация времени; не в контейнерах) и лимит `journald`
  (`/etc/systemd/journald.conf.d/99-ansible.conf`).
- Автоперезагрузка выключена по умолчанию (`auto_reboot: false`), `wizard.sh` её не
  включает, а `unattended-upgrades` включён (`auto_updates_enabled: true`).
  `auto_reboot=true` включает автоперезагрузку после обновлений
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
`PasswordAuthentication`, `MaxAuthTries`, `X11Forwarding`. Порт можно сменить
(`ssh_port`, см. «Расширенная настройка SSH»).
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

## Предполётные проверки (preflight)

Перед любыми изменениями роль `preflight` проверяет всё, что может оставить
вас без доступа или оборвать запуск на полпути. Любая неудача **сразу
останавливает весь запуск** (`any_errors_fatal`), система остаётся нетронутой:

- версия ansible-core (2.15+), корректность `ssh_port`;
- новый администратор может войти (ключ или пароль) и пользоваться `sudo`
  (ключ без пароля требует `admin_user_sudo_nopasswd: true`);
- отключение паролей SSH возможно только при наличии ключа у администратора;
  `ssh_allow_users` обязан содержать администратора;
- новый порт SSH не занят другой службой;
- свободное место (`preflight_min_disk_mb`, 1024 МБ) и память
  (`preflight_min_memory_mb`, 400 МБ);
- доступен репозиторий Docker по HTTPS (`preflight_check_network: false`
  отключает проверку).

Только проверки, без изменений: `./run.sh --preflight`.

## Теги

Запуск части плейбука: `./run.sh --tags ssh,firewall` (или
`ansible-playbook site.yml --tags ...`). Предполётные проверки, учётка
администратора и итоговая сводка выполняются всегда.

| Тег | Что выполняется |
|---|---|
| `base`, `ssh`, `firewall`, `kernel`, `docker`, `crowdsec` | одноимённые роли |
| `docker_prune` | очистка Docker |
| `hardening` | вся дополнительная защита |
| `sysctl`, `sudo`, `pwquality`, `coredump`, `modules`, `banner`, `cron`, `mac`, `auditd`, `lynis`, `logrotate` | отдельные пункты защиты |

## Расширенная настройка SSH

| Переменная | Что делает |
|---|---|
| `ssh_port` | порт SSH. Правило firewall для него создаётся автоматически (UFW `limit`/`allow` или firewalld), на RHEL ставится метка SELinux `ssh_port_t`, на Ubuntu 24.04 переопределяется `ssh.socket`. Правило для порта 22 остаётся, пока не включён `firewall_close_old_ssh_port: true`; тогда плейбук сначала проверяет, что sshd слушает новый порт |
| `ssh_harden` + `ssh_password_auth: false` | запрет входа по паролю и root |
| `ssh_harden_extra` | `LoginGraceTime 30`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `MaxSessions 10`, запрет agent forwarding. **TCP-forwarding остаётся разрешённым**, поэтому `ssh -L/-D`, `ProxyJump` и SSH-туннели работают |
| `ssh_allow_users`, `ssh_allow_groups` | кто может входить |
| `ssh_modern_crypto` | только современные KEX/шифры/MAC |
| `harden_banner` | баннер до входа |

Перед сменой порта откройте его и в firewall хостера и не закрывайте текущую
сессию, пока не войдёте по новому порту.

## Дополнительная защита (всё выключено по умолчанию)

Включается по пунктам в `vars.local.yml` (мастер спрашивает про каждый) и
отключается обратно: выставьте `false` и запустите плейбук снова.

- **`harden_sysctl`** — `kernel.kptr_restrict=2`, `kernel.yama.ptrace_scope=1`,
  `kernel.unprivileged_bpf_disabled=1`, `net.core.bpf_jit_harden=2`,
  `fs.protected_*`, `tcp_rfc1337`. Не трогает `ip_forward` и `rp_filter`
  (нужны VPN, прокси и Docker). Побочный эффект: `ptrace_scope=1` не даёт
  обычному пользователю подключаться отладчиком к чужим процессам.
- **`harden_sudo`** — файл `/etc/sudoers.d/91-ansible-hardening`:
  - `use_pty`: команда выполняется в собственном псевдотерминале, поэтому
    фоновый процесс не может после завершения `sudo` писать в ваш терминал или
    подсовывать в него нажатия клавиш;
  - `logfile="/var/log/sudo.log"` (+ `log_host, log_year`): каждая команда
    пишется в отдельный файл, помимо журнала системы; ротация настраивается
    автоматически;
  - `timestamp_timeout=5`: после ввода пароля `sudo` не спрашивает его ещё
    5 минут (в дистрибутивах по умолчанию 15). Файл проверяется `visudo -cf`.
- **`harden_password_policy`** — `libpwquality`: минимум 12 символов, минимум
  3 класса (строчные, прописные, цифры, спецсимволы), не более 3 одинаковых
  подряд, проверка по словарю и на совпадение с логином. Действует только при
  смене пароля (`passwd`) и не затрагивает вход по ключу и уже заданные
  пароли; root политикой не ограничен. Значения: `harden_pwquality_*`.
- **`harden_coredumps`** — `* hard core 0` в `limits.d`, `Storage=none` для
  systemd-coredump, `kernel.core_pattern=|/bin/false`, `fs.suid_dumpable=0`.
- **`harden_kernel_modules`** — `install <модуль> /bin/false` для `dccp`, `sctp`,
  `rds`, `tipc`, `cramfs`, `freevxfs`, `hfs`, `hfsplus`, `jffs2`. В списке нет
  ничего, что используют WireGuard/OpenVPN/прокси (`tun`, `wireguard`) или Docker
  (`overlay`, `veth`, `br_netfilter`); `verify.sh` это проверяет. Уберите `sctp`,
  если пользуетесь SCTP; `usb-storage` добавляется через
  `harden_blacklist_modules_extra`. Уже загруженные модули остаются до перезагрузки.
- **`harden_banner`** — текст `harden_banner_text` до входа по SSH и в `/etc/motd`
  (копия прежнего motd сохраняется как `/etc/motd.<дата>~`).
- **`harden_cron_at`** — `/etc/cron.allow` и `/etc/at.allow`: root, администратор
  и `harden_cron_allow_users`. Системные задания в `/etc/cron.d` не затрагиваются,
  а `crontab -e` у остальных пользователей перестанет работать.
- **`harden_mac`** — Debian/Ubuntu: пакеты AppArmor обновляются до последних,
  параметры `apparmor=1 security=apparmor` добавляются в GRUB, служба включена,
  профили в режиме complain выводятся предупреждением. RHEL: пакеты SELinux
  обновляются, режим `harden_selinux_mode` (по умолчанию `enforcing`). Если
  SELinux был выключен, он сначала переводится в `permissive` с полной
  переразметкой при следующей загрузке; после перезагрузки запустите плейбук ещё раз.
  В контейнерах пропускается.
- **`harden_auditd`** — пакет, служба и правила: `passwd`/`group`/`shadow`/sudoers/
  sshd_config и команды, выполненные от root вошедшим пользователем. В контейнерах
  пропускается. Правила неизменяемыми (`-e 2`) не делаются.
- **`harden_lynis`** — ставит Lynis (`sudo lynis audit system`); Debian/Ubuntu.
- **`logrotate_enabled`** (включён) — пакет и таймер logrotate, ротация
  `/var/log/sudo.log` и файлов из `logrotate_extra_logs`. Docker, CrowdSec, UFW,
  auditd и journald ротируют свои логи сами.
- **`docker_prune_enabled`** — таймер systemd раз в неделю выполняет
  `docker system prune --force --filter until=168h`: удаляет остановленные
  контейнеры, неиспользуемые сети, образы без тегов и кэш сборки старше недели.
  Тома не трогаются (только при `docker_prune_volumes: true`; это удаляет данные).
  `docker compose stop` старше недели тоже будет вычищен — тома при этом сохранятся.

### CrowdSec вместо правил UFW для Docker

Правила UFW для опубликованных портов Docker не добавляются. Вместо этого
(`crowdsec_docker_protection`, включено) bouncer CrowdSec фильтрует и цепочку
`DOCKER-USER` (iptables), и хук forward (nftables): забаненные адреса не
доберутся и до портов контейнеров. Роль `crowdsec` запускается после `docker`,
а systemd-drop-in запускает bouncer после `docker.service`. Рекомендация
`docker_default_bind_ip: 127.0.0.1` остаётся в силе: CrowdSec банит только
замеченных атакующих, а не закрывает порты.

## Откат изменений

Основной способ: **вернуть переменную в `false` (или удалить) и запустить
плейбук снова** — созданные файлы будут удалены. Часть эффектов видна только
после перезагрузки (уже применённые sysctl, загруженные модули).

| Что откатить | Как |
|---|---|
| Любой пункт защиты | `harden_<имя>: false`, `./run.sh --tags <тег>` |
| Порт SSH | `ssh_port: 22`, запуск; удалите лишнее правило: `sudo ufw delete allow 2222/tcp` (UFW) или `sudo firewall-cmd --permanent --remove-port=2222/tcp && sudo firewall-cmd --reload` |
| SSH целиком | `sudo rm /etc/ssh/sshd_config.d/00-ansible-hardening.conf && sudo systemctl reload ssh` (`sshd` на RHEL); копии изменённых файлов: `/etc/ssh/*.<дата>~` |
| ssh.socket (Ubuntu 24.04) | `sudo rm /etc/systemd/system/ssh.socket.d/ansible-port.conf && sudo systemctl daemon-reload && sudo systemctl restart ssh.socket` |
| sudo | `sudo rm /etc/sudoers.d/91-ansible-hardening` (при потере доступа к sudo: `su -` и то же самое) |
| Баннер | `harden_banner: false`; прежний motd — `/etc/motd.<дата>~` |
| AppArmor в GRUB | `harden_mac: false` (удаляет `/etc/default/grub.d/99-ansible-apparmor.cfg` и обновляет GRUB), перезагрузка |
| SELinux | `sudo setenforce 0` (до перезагрузки) или `SELINUX=permissive` в `/etc/selinux/config`; `/.autorelabel` удаляется вручную |
| auditd | `harden_auditd: false`; пакет: `sudo apt purge auditd` / `sudo dnf remove audit` |
| Модули ядра | `harden_kernel_modules: false`, перезагрузка |
| Очистка Docker | `docker_prune_enabled: false` |
| CrowdSec для Docker | `crowdsec_docker_protection: false`, запуск (bouncer вернётся к `INPUT`) |
| Потерян доступ по SSH | консоль хостера → удалите drop-in SSH (строка выше), проверьте `sudo ss -ltnp`, правила firewall и firewall хостера |

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
├── run.sh                     # установка Ansible + запуск (читает/создаёт vars.local.yml)
├── wizard.sh                  # мастер вопросов, создаёт vars.local.yml
├── vars.example.yml           # справочник по всем настройкам
├── verify.sh
├── ci/                        # настройки для проверки идемпотентности в CI
├── .github/workflows/idempotency.yml
└── roles/                     # у каждой роли свои defaults/main.yml
    ├── preflight/     # проверки до начала изменений (любая ошибка — стоп)
    ├── hardening/     # необязательная защита: sudo, pwquality, auditd, AppArmor/SELinux, ...
    ├── base/          # обновление, пакеты, автообновления, chrony, journald, trippy
    ├── admin_user/    # admin_user, пароль/ключи, группа sudo/wheel, sudoers
    ├── ssh/           # опциональная настройка sshd (ssh_harden, по умолчанию выключена)
    ├── firewall/      # UFW или firewalld (SSH на порту 22 разрешён)
    ├── crowdsec/      # сервис, LAPI, collections, bouncer, whitelist
    ├── kernel/        # BBR, IPv6, sysctl hardening, zram
    └── docker/        # официальный Docker CE и daemon.json
```

## Безопасность и ограничения

- Проверка идемпотентности: `.github/workflows/idempotency.yml` дважды запускает
  плейбук на чистом раннере (профили `default` и `hardened` из `ci/`); второй
  запуск должен дать `changed=0`.
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
