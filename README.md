# 🕷️ BugBounty Auto-Recon

## Быстрый старт

```bash
# 1. Установить зависимости
chmod +x recon.sh
./recon.sh --install

# 2. Заполнить Telegram данные в recon.sh (строки 38-39)
# TG_BOT_TOKEN и TG_CHAT_ID

# 3. Проверить Telegram
./recon.sh --test-tg

# 4. Запустить сканирование
./recon.sh -d target.com
```

## Telegram Bot

```bash
# Установить зависимости
pip3 install python-telegram-bot --break-system-packages

# Заполнить BOT_TOKEN и ALLOWED_CHAT_ID в bot.py (строки 27-28)

# Запустить бота
python3 bot.py
```

### Команды бота

| Команда | Описание |
|---|---|
| `/programs` | Список программ |
| `/add_program <имя>` | Создать программу |
| `/add_domain <программа> <домен>` | Добавить домен |
| `/add_header <программа> <ключ> <значение>` | Добавить заголовок (стелс) |
| `/scan <программа>` | Запустить сканирование |
| `/status` | Активные сканы |
| `/stop <программа>` | Остановить скан |

## Кастомные заголовки (стелс-сканирование)

Для программ с жёстким rate-limiting добавь заголовки через бота:

```
/add_header HackerOne X-Bug-Bounty myhandle123
/add_header HackerOne User-Agent Mozilla/5.0 (compatible; bugbounty)
```

Или напрямую через recon.sh:

```bash
./recon.sh -d target.com \
  -H 'X-Bug-Bounty: myhandle' \
  -H 'User-Agent: Mozilla/5.0'
```

## Структура результатов

```
~/recon-results/target.com/TIMESTAMP/
├── passive/         — субдомены из пассивных источников
├── active/
│   ├── live_hosts.txt         — живые хосты
│   ├── services_report.txt    — сервисы и версии (nmap -sV)
│   └── interesting_ports.txt  — нестандартные порты
├── surface/
│   └── interesting_urls.txt   — /admin /api /debug
├── js/
│   └── js_secrets.txt         — потенциальные секреты в JS
├── vulns/
│   └── nuclei_findings.txt    — автоматические находки
└── reports/
    └── summary.md             — итоговый отчёт
```
