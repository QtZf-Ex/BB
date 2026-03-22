# BugBounty Auto-Recon

## Быстрый старт

```bash
# 1. Клонировать
git clone https://github.com/QtZf-Ex/BB && cd BB
chmod +x recon.sh

# 2. Установить зависимости
./recon.sh --install

# 3. Вписать Telegram токен в recon.sh (строки 47-48)
nano recon.sh
# TG_BOT_TOKEN="..."
# TG_CHAT_ID="..."

# 4. Тест Telegram
./recon.sh --test-tg

# 5. Запуск
./recon.sh -d target.com
```

## Telegram Bot (управление из телефона)

```bash
# Установить зависимости бота
pip install python-telegram-bot --break-system-packages

# Заполнить в bot.py:
# BOT_TOKEN = "..."
# AUTHORIZED_USERS = [123456789]

# Запустить
python3 bot.py
```

### Возможности бота
- Создавать программы bug bounty (группы доменов)
- Добавлять/удалять домены из бота
- Настраивать HTTP заголовки на программу (Authorization, Cookie...)
- Настраивать rate limit на программу
- Запускать/останавливать сканирования
- Получать отчёты в Telegram

## Опции recon.sh

```
-d, --domain DOMAIN      Целевой домен
-o, --output DIR         Папка результатов
-t, --threads N          Потоки (default: 30)
--headers-file FILE      Файл с HTTP заголовками
--deep                   Глубокий режим
--only-passive           Только Phase 1
--install                Установить зависимости
--test-tg                Тест Telegram
```

## Файл заголовков

```
# headers.txt — один заголовок на строку
Authorization: Bearer xxxxxxxxxxxxxxxx
X-Bug-Bounty: @yourusername
Cookie: session=abc123
```

```bash
./recon.sh -d target.com --headers-file headers.txt
```

## Структура результатов

```
~/recon-results/target.com/TIMESTAMP/
├── passive/          # crt.sh, subfinder, wayback
├── active/           # httpx, naabu, nmap XML
├── surface/          # ffuf, исторические URL, CORS
├── js/               # JS files, secrets
├── vulns/            # nuclei findings
└── reports/
    └── summary.md    # Итоговый отчёт (включает services table)
```

## Что исправлено в v3.2

| # | Проблема | Исправление |
|---|---|---|
| 1 | TG: литеральный `\n` | `printf '%b'` интерпретирует `\n` как перевод строки |
| 2 | `grep -c \|\| echo 0` — двойной вывод | Убрали `\|\| echo 0` |
| 3 | ffuf зависает, спам в терминал | `timeout 180` + `-rate 30` + `>/dev/null` |
| 4 | massdns не найден | Сборка из исходников + dnsx fallback |
| 5 | getJS не устанавливается | Заменён на `katana` (ProjectDiscovery) |
| 6 | pip PEP 668 Debian 12 | `--break-system-packages` |
| 7 | Ошибка line 572 | `touch` всех файлов сразу при старте |
| NEW | Нет данных о сервисах | Парсинг httpx JSON + nmap XML в отчёт |
| NEW | Нет поддержки заголовков | `--headers-file` + передача в httpx/ffuf/nuclei |
