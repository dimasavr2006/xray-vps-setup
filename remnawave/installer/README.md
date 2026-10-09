# Установщик Remnawave: Linux, Bash и Docker Compose

На VPS установщик выполняет обычные команды APT, Docker Compose, curl, jq,
OpenSSL и nftables. Python-код и упакованный Python-runtime удалены из точки
входа. `rw-setup.sh` и `uninstall.sh` — самодостаточные читаемые Bash-файлы.

Код развёртывания реализован. Локально проверены реальные контейнеры Panel
3.4.5, Node 3.4.2, PostgreSQL, Valkey и subscription-page, административный API,
регистрация профиля/ноды/Hosts/squads, штатный SECRET_KEY и Caddy Auth/MFA.
На FI Debian 13 прошли внешние HTTPS/TCP/XHTTP, подписки и перевыпуск
сертификата через ACME staging. В чистом Debian 13 WSL с собственным Docker
прошли три роли, SSH/sudo-подключение отдельной ноды, восстановление,
обновление и откат базы. WSL-проверка не заменяет чистый VPS с публичным DNS.
48 часов наблюдения FI и привязка MFA владельцем остаются открытыми.

## Запуск

Первый целевой VPS — Debian 13 amd64. Установка выполняется от root.
Устанавливаются только необходимые пакеты; Docker берётся из официального
APT-репозитория. Автоматические full-upgrade, reboot, смена SSH и BBR отсутствуют.

Формат запуска нового комплекта:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/remnawave/rw-setup.sh)
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/remnawave/uninstall.sh)
```

Новый комплект размещается в `remnawave/`. Старые корневые скрипты Marzneshin
сохраняют прежнее поведение. Выпуск остаётся тестовым до завершения приёмки.

Из локальной копии:

```bash
bash rw-setup.sh
bash rw-setup.sh --role panel-node --config /private/install.json
bash rw-setup.sh --config /private/install.json --dry-run
```

Без config скрипт спрашивает роль, домены, IP и данные администратора. Пароли
генерируются, а не вводятся в публичный JSON. По умолчанию установка находится
в `/opt/pdm-remnawave/<environment_id>`. Другой каталог задаётся через `--output`.
Предварительный `--dry-run` требует только установленного jq и не запускает сервисы.

## Что делает установка

1. Проверяет ОС/архитектуру, DNS A/AAAA, ресурсы, время, SSH-конфигурацию,
   firewall, занятые TCP-порты IPv4/IPv6, публикации Docker NAT и subnet.
2. Создаёт секреты один раз и структурированные конфиги через jq.
3. Загружает образы по закреплённым digest и проверяет Caddyfile.
4. Устанавливает собственные правила nftables до запуска открываемых сервисов.
5. Запускает PostgreSQL, Valkey и панель через `docker compose up -d --wait`.
6. Создаёт первого администратора через закрытый API, выпускает ограниченные
   служебные токены для установщика и subscription-page.
7. Через API создаёт профиль Xray, запись ноды, Hosts и отдельные TCP/XHTTP squads.
8. Получает настоящий SECRET_KEY панели, запускает Caddy и ноду, проверяет здоровье.

JSON профиля Xray служит входом для API. Он не монтируется в ноду и не конкурирует
с конфигурацией, которую отправляет Remnawave. Новые пользователи и назначения
доступа существующим аккаунтам установщиком не создаются.

Данные администратора: `private/admin.json`; отдельный пароль Caddy Auth:
`auth_password` в `private/secrets.json`. Владелец завершает MFA при первом входе.
Caddy защищает административный сайт. Панель и подписки могут использовать один
домен: тогда публичные подписки получают отдельный HTTPS-порт `9444`
(`ports.subscription_https`). CORS содержит полный HTTPS origin с портом.

## Роли и параметры

Примеры: [panel](examples/panel.json), [node](examples/node.json),
[panel-node](examples/panel-node.json), [FI parallel](examples/fi-parallel.json),
[FI compact с одним доменом](examples/fi-compact-single-domain.json).
Это примеры с зарезервированными IP/доменами, не готовые параметры production.

Основные поля: `schema_version: 1`, `environment_id` (3–20 строчных букв,
цифр и дефисов), `role`, `network_mode`, `domains`, `public_addresses`,
`panel_addresses`, `admin`, `ports`, `resources`, `docker_subnet`, `acme`,
`node_country`, `existing_caddy`.

| Режим | Панель HTTPS | Reality / XHTTP | API ноды | HTTP |
| --- | --- | --- | --- | --- |
| panel | 443 | — | — | 80 |
| node | — | 443 / 8443 | 2222 | 80 |
| panel-node | 9443 | 443 / 8443 | 2222 | 80 |
| fi-parallel | 9443 | 24443 / 28443 | 2222 | 18080 loopback |

Reality target — loopback 14123. Собственный Caddy admin API — loopback 12019.
API панели/метрики/подписок — loopback 13000/13001/13010. Порты можно переопределить
явно; совпадения и занятые порты являются ошибкой. FI сохраняет прежние
80/443/8443/37241/4123/53042.

`public_addresses` содержит полный ожидаемый набор A/AAAA. IPv6 нормализуется;
лишний AAAA и неизвестный результат DNS блокируют запуск. `panel_addresses`
нужен отдельной ноде для source allowlist управления. `management_address`
позволяет задать приватный адрес API ноды; по умолчанию это домен ноды.
`docker_subnet` — отдельный
private IPv4 /24, по умолчанию 172.29.240.0/24; пересечение с действующими сетями
не исправляется автоматической сменой адресов.

`acme` — `production` или `staging`. Для FI задаются путь Caddyfile существующей
системы, контейнер и HTTPS URL проверки старого сайта. Установщик сохраняет
копию, проверяет полный конфиг и делает graceful reload. Изменение файла
сохраняет inode Docker bind mount; при ошибке выполняется откат.

Бюджет диска по умолчанию: образы 3 GiB + данные 1 GiB + восстановление 2 GiB +
резерв 1 GiB. Если все закреплённые образы уже загружены, их бюджет повторно
не вычитается из свободного места. Стандартная совместная установка требует
1920 MiB свободной RAM сверх действующих служб. Профиль `resources.profile:
"compact-test"` разрешён только для тестов: суммарные жёсткие лимиты контейнеров
1152 MiB и ещё 128 MiB запаса, без роста swap новых контейнеров. Лимиты:
панель 512, PostgreSQL 160, Valkey 32, подписки 192, Caddy 96, нода 160 MiB.
Параллельный FI с 2 GiB RAM прошёл свежий preflight и реальный запуск 09.10.2026.
Production-ориентир —
2 CPU, 4 GiB RAM и 20 GiB свободного диска. Чужие образы и архивы не очищаются.

## Отдельная нода

`--role node` подготавливает сервер, образы, конфиги и firewall без панели.
Без штатного ключа она получает статус `node-prepared-awaiting-attachment`.

После подготовки ноды в стандартном каталоге, на сервере панели:

```bash
bash /opt/pdm-remnawave/panel-test/rwctl node attach \
  --ssh root@NODE_HOST --node-config /private/node.json
```

SSH host key должен уже находиться в known_hosts; используются BatchMode и
StrictHostKeyChecking=yes. Сверяются параметры подготовленного хоста. Профиль
ноды доставляется в панель через API; в ноду по SSH передаётся только пакет
подключения, а не токен панели. Пакет ограничен часом и привязан к config fingerprint.
Повтор сохраняет уже работающий ключ управления и зарегистрированные UUID.

## Обслуживание и сохранность

В каталоге установки сохраняется самодостаточный `rwctl`:

```bash
bash /opt/pdm-remnawave/fi-test/rwctl doctor
bash /opt/pdm-remnawave/fi-test/rwctl preflight
bash /opt/pdm-remnawave/fi-test/rwctl backup --archive /private-backups/fi-test.tgz
bash rwctl restore --archive /private-backups/fi-test.tgz --output /opt/pdm-remnawave/fi-test
bash /opt/pdm-remnawave/fi-test/rwctl upgrade --versions /private/versions.json
bash /opt/pdm-remnawave/fi-test/rwctl rollback --archive /private-backups/pre-upgrade.tgz
bash /opt/pdm-remnawave/fi-test/rwctl tls-test
```

Manifest формата 2 помечен `implementation: bash-docker`. Inventory и lock имеют
версии форматов и environment_id. Секреты — отдельные файлы 0600 в каталоге 0700;
логи не выводят токены/пароли. Повтор использует сохранённые секреты, а изменение
config fingerprint/чужой объект API вызывает остановку. Операции блокируются flock.

Backup включает согласованный pg_dump, файлы установки и тома Caddy с MFA и
сертификатами; архив проверяется и закрывается правами 0600. Перед переключением
его требуется скопировать вне VPS вместе с `.sha256`. Restore предназначен
для пустого каталога или продолжения того же восстановления. Он проверяет
архив/manifest/digest, пересоздаёт доверенные Compose/Caddy, не запускает код
из backup и сохраняет ключи, API-ID, MFA и сертификаты. Можно изменить IP;
ID, роль, домены, порты и subnet сохраняются.

Upgrade сначала загружает и проверяет официальные образы по digest, затем
останавливает записи и создаёт согласованный снимок. Неудачная проверка
возвращает прежние образы, всю БД и Caddy. Major PostgreSQL не меняется этой
командой. Rollback также создаёт снимок текущего состояния перед заменой БД.
Для смены версии панели со схемой `pdm_stats` требуется проверенная миграция.

SSH защищается отдельными командами после установки:

```bash
bash /opt/pdm-remnawave/node-test/rwctl ssh prepare --admin-user vpnadmin --public-key /private/admin.pub
bash rwctl ssh harden --config /private/node.json --output /opt/pdm-remnawave/node-test --ssh vpnadmin@NODE_HOST
```

Проверяются новый вход и `sudo -n`, конфигурация sshd и повторное подключение
после reload. Watchdog возвращает прежнюю политику через 60 секунд без
подтверждения. Обычный root-вход закрывается; ограниченные root-ключи
quota-agent сохраняются через `PermitRootLogin forced-commands-only`.
Удаление установки сохраняет созданного SSH-администратора и настройки входа.
На рабочем FI SSH автоматически не менялся.

TLS-test временно направляет только HTTP-01 проверки в отдельный Caddy,
получает и перевыпускает staging-сертификат, затем возвращает исходный HTTP
маршрут. Production-сертификат и MFA остаются в своём хранилище.

## Удаление

```bash
bash uninstall.sh --output /opt/pdm-remnawave/fi-test --dry-run
bash uninstall.sh --output /opt/pdm-remnawave/fi-test
bash uninstall.sh --output /opt/pdm-remnawave/fi-test --purge
```

Без `--output` предлагается выбор manifest под `/opt/pdm-remnawave`. Для удаления
подтверждается environment_id; `--yes` даёт явное подтверждение для автоматизации.
По умолчанию Docker volumes сохраняются, а конфиги/ключи архивируются под
`/var/backups/pdm-remnawave/` перед удалением. `--purge` удаляет также свои тома.
`--prepared-only` разрешён только для незапущенного подготовленного комплекта.

Удаляются только собственные контейнеры/сети/тома по Compose labels и дополнительной
метке владения окружением/каталогом. Проверяются manifest и хеши; изменения после
подтверждения считаются конфликтом. Собственные firewall/systemd/UFW-дополнения
удаляются отдельно. Старый Caddy восстанавливается только при совпадении сохранённого
хеша. Неуправляемые файлы и резервные копии в каталоге остаются. Docker Engine,
образы, чужие службы, SSH и общий firewall не удаляются/не сбрасываются.
Удаление API-объектов отдельной ноды на удалённой панели остаётся ручным шагом.

## Проверки и сборка

```bash
bash installer/build-entrypoints.sh
bash installer/build-entrypoints.sh --check
shellcheck -S warning rw-setup.sh uninstall.sh rwctl installer/build-entrypoints.sh
bash tests/bash/unit.sh
bash tests/bash/recovery-unit.sh
sudo bash tests/bash/http-entrypoints.sh
sudo bash tests/bash/live-compose.sh
```

Актуальная проверка 09.10.2026: 41 Bash-проверка; реальный wget/process-substitution
из каталога без checkout; реальный стек в отдельном локальном Docker-проекте,
администратор и scoped API-токены, профиль/нода/Hosts/squads, подключённый Xray,
здоровая subscription-page, Caddy adapt/validate с MFA. Ранние 54 Python-теста
относятся к удалённому прототипу и не являются тестами этой реализации.

Исходники: `installer/bash/*.sh`, схема jq и Caddy-шаблон. Bash-сборщик объединяет
их с public lock в три файла `rw-setup.sh`, `uninstall.sh`, `rwctl`. Публикация
опубликован в каталоге `remnawave/` существующего репозитория, commit `849821f`.
Реальные GitHub raw файлы совпали с проверенными Bash-исходниками; запуск
через process substitution и scoped uninstall прошёл. На FI Debian 13 amd64 проверена параллельная
установка с одним `fl.wf.md`, доверенным сертификатом, TCP/XHTTP с внешнего
клиента, публичными подписками, закрытием внутренних портов, повтором с
сохранением ключей/API UUID и backup. Старые контейнеры не перезапускались.
Отчёт: [tests/verification.fi.json](../tests/verification.fi.json).
На отдельном Debian 13 WSL прошли чистые panel/node/panel-node и полный CLI
backup/purge/restore/upgrade/rollback. Проверен откат после добавления новой
таблицы и реальное обновление PostgreSQL 18.3 → 18.4 на компонентном стенде.
41 основной и 9 дополнительных Bash-проверок проходят. Отчёт обслуживания:
[verification.maintenance.json](../tests/verification.maintenance.json).
FI наблюдается каждые пять минут до **11.10.2026 02:26 МСК**. Привязка MFA
владельцем и чистый VPS с публичным DNS остаются открытыми. На FI нет глобального
IPv6; IPv6-проверки выполняются отдельно в сетевом стенде.
