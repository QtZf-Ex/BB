# BugBounty Auto-Recon v3.3

## Быстрый старт

```bash
git clone https://github.com/QtZf-Ex/BB && cd BB
chmod +x recon.sh
./recon.sh --install

# Вставь в recon.sh строки 52-53:
# TG_BOT_TOKEN="..."
# TG_CHAT_ID="..."

./recon.sh --test-tg
./recon.sh -d target.com
```

## Что исправлено в v3.3

| Проблема | Причина | Исправление |
|---|---|---|
| Live Hosts = 0 | httpx сканировал только `:80/:443`, nginx на `:8443` не попадал | httpx теперь сканирует **все IP:PORT** из naabu |
| nmap XML пустой | nmap не запускался: `nmap_targets.txt` был пуст | nmap запускается на **ВСЕ хосты** с любыми открытыми портами |
| Interesting ports = 0 | фильтр искал только конкретные порты, naabu нашёл другие | Interesting = **все порты кроме 80/443** |
| Нет attack URLs | отчёт не давал готовых URL для Burp | Новый файл **`attack_urls.txt`** + раздел в отчёте |

## Telegram Bot v2.0

```bash
pip install python-telegram-bot apscheduler --break-system-packages

# Заполни в bot.py:
# BOT_TOKEN = "..."
# AUTHORIZED_USERS = [123456789]  # @userinfobot

python3 bot.py
```

### Как добавить домены (UX fix)
1. `/start` → **➕ Новая программа**
2. Введи название: `hackerone_target`
3. **Автоматически** предлагается ввести первый домен
4. Введи: `target.com` → добавить ещё или идти к сканированию
5. **▶️ Скан**

### Cron — автоматическое сканирование
```
/start → 🕐 Cron → выбери программу → введи интервал в часах
```
Пример: 24 = скан раз в сутки автоматически

## Структура отчёта

```
## Все открытые порты          <- ВСЕ порты из naabu
## Attack URLs                  <- Готовые URLs для Burp
## Live Hosts & Technologies    <- httpx с технологиями
## Open Ports & Service Versions <- nmap версии сервисов
```

## Заголовки против блокировки

```bash
# Создать файл headers.txt:
Authorization: Bearer TOKEN
X-Bug-Bounty: @yourusername
Cookie: session=abc123

# Запуск с заголовками:
./recon.sh -d target.com --headers-file headers.txt

# Через бот:
# Программа → 🔑 Заголовки → ➕ Добавить
```

## Файлы результатов

```
~/recon-results/target.com/TIMESTAMP/
├── passive/
│   ├── all_subs_raw.txt     # все субдомены
│   └── wayback_urls.txt     # исторические URL
├── active/
│   ├── open_ports.txt       # ВСЕ открытые порты
│   ├── interesting_ports.txt # нестандартные порты
│   ├── attack_urls.txt      # <- ГЛАВНЫЙ ФАЙЛ ДЛЯ BURP
│   ├── live_hosts.txt       # живые хосты
│   └── nmap_services.xml    # версии сервисов
├── surface/
│   └── interesting_urls.txt
├── js/
│   └── js_secrets.txt
├── vulns/
│   └── nuclei_findings.txt
└── reports/
    └── summary.md           # полный отчёт
```
