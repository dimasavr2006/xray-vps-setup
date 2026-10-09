# Remnawave — установщик для Linux

Первый поддерживаемый сервер: **Debian 13 amd64**, запуск от root.
Установщик использует Bash, APT, Docker Compose, curl, jq, OpenSSL и nftables.
Для работы установщика Python не требуется. Checkout репозитория на VPS не нужен.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/remnawave/rw-setup.sh)
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/remnawave/uninstall.sh)
```

Скрипт предлагает панель, отдельную ноду или панель + ноду. Домены панели,
подписок и ноды могут совпадать; панель и подписки тогда используют разные
HTTPS-порты. Пароли и Reality-ключи генерируются один раз и сохраняются
в закрытом каталоге установки. При первом входе нужно привязать MFA.

Для установки с явными портами, адресами и бюджетом ресурсов используйте
[JSON-примеры](installer/examples) и `--config /private/install.json`.
Мастер параллельной установки спрашивает параметры действующего Caddy и
профиль ресурсов. JSON-пример FI требует подстановки своих параметров.
Разные домены панели, подписок и заглушки могут указывать на один IP.

```bash
bash /opt/pdm-remnawave/ENV/rwctl doctor
bash /opt/pdm-remnawave/ENV/rwctl backup --archive /private-backups/ENV.tgz
bash rwctl restore --archive /private-backups/ENV.tgz --output /opt/pdm-remnawave/ENV
bash /opt/pdm-remnawave/ENV/rwctl upgrade --versions /private/versions.json
bash /opt/pdm-remnawave/ENV/rwctl rollback --archive /private-backups/pre-upgrade.tgz
bash /opt/pdm-remnawave/ENV/rwctl stats install --stats-port 13100 --dry-run
bash /opt/pdm-remnawave/ENV/rwctl stats install --stats-port 13100
bash /opt/pdm-remnawave/ENV/rwctl stats status
bash /opt/pdm-remnawave/ENV/rwctl tokens status
bash /opt/pdm-remnawave/ENV/rwctl tokens rotate --token all
bash /opt/pdm-remnawave/ENV/rwctl mfa status
bash /opt/pdm-remnawave/ENV/rwctl mfa guide
```

Backup вместе с `.sha256` храните вне VPS. Restore сохраняет ключи/API-ID,
БД, сертификаты и MFA. Upgrade включает снимок и возврат БД при неудаче;
major PostgreSQL меняется отдельной миграцией. Удаление сохраняет данные по
умолчанию; `--purge` удаляет только собственные тома. Docker, чужие службы,
неуправляемые файлы и SSH-доступ сохраняются.

Проверено: FI Debian 13, один домен и текущие 2 GiB RAM в compact-test,
внешние HTTPS/TCP Reality/XHTTP, публичные подписки, повтор, staging TLS;
три роли на чистом Debian 13 WSL с native Docker, SSH/sudo attachment,
реальные клиенты отдельной ноды, IPv4/IPv6 firewall и полный CLI
backup/purge/restore/upgrade/rollback. Stats addon также прошёл восстановление,
обновление, откат и отказ с возвратом прежнего стека; работает на FI.
Токены имеют ручную ротацию с журналом, проверкой перед отзывом и возвратом
при отказе активации. SIGKILL при bootstrap и записи файлов, потеря API-ответов,
полный TOTP-вход и сохранение MFA после restore проверены.
Проходят 44 + 9 + 7 + 7 + 7 = 74 Bash-проверки и
реальный запуск через wget/process substitution.

Комплект остаётся тестовым. Наблюдение остановлено по решению владельца:
85 выборок без ошибок, 48 часов не завершены. Личная MFA-привязка владельца
на FI подтверждена. Чистый VPS с публичным DNS остаётся отдельной приёмкой.
Этот установщик не переносит рабочую базу и не переключает Telegram-бота.
Корневые скрипты данного репозитория по-прежнему устанавливают Marzneshin.

Исходники и закреплённые образы: [installer](installer).
Интервальная статистика: [stats](stats).
Проверки: [tests](tests). Сборка: `bash installer/build-entrypoints.sh`;
проверка актуальности: `bash installer/build-entrypoints.sh --check`.
