#!/usr/bin/env python3
"""
BugBounty Recon Bot v1.0

Установка:
  pip3 install python-telegram-bot --break-system-packages
  python3 bot.py

Команды:
  /programs                       - список программ
  /add_program <имя>              - создать программу
  /del_program <имя>              - удалить программу
  /list <программа>               - детали программы
  /add_domain <программа> <домен> - добавить домен
  /del_domain <программа> <домен> - удалить домен
  /add_header <prog> <key> <val>  - добавить заголовок (стелс)
  /del_header <prog> <key>        - удалить заголовок
  /scan <программа> [домен]       - запустить сканирование
  /status                         - активные сканирования
  /stop <программа>               - остановить скан
"""

import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path

try:
    from telegram import Update
    from telegram.ext import Application, CommandHandler, ContextTypes
except ImportError:
    print("Установи: pip3 install python-telegram-bot --break-system-packages")
    sys.exit(1)

# ═══════════════════════════════════════════════════
#  ВСТАВЬ СВОИ ДАННЫЕ (строки 38-39)
BOT_TOKEN       = ""   # "7123456789:AAHxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
ALLOWED_CHAT_ID = ""   # "123456789" - только этот chat_id управляет ботом
#                        Группа/канал: "-1001234567890"
# ═══════════════════════════════════════════════════

RECON_SCRIPT = Path(__file__).parent / "recon.sh"
DATA_FILE    = Path.home() / ".config" / "recon" / "programs.json"

# pid -> {proc, domain}
active_scans: dict = {}


# ─── DATA ───────────────────────────────────────────

def load_data() -> dict:
    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    if DATA_FILE.exists():
        try:
            return json.loads(DATA_FILE.read_text())
        except Exception:
            pass
    return {"programs": {}}


def save_data(data: dict):
    DATA_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False))


# ─── AUTH ────────────────────────────────────────────

def allowed(update: Update) -> bool:
    if not ALLOWED_CHAT_ID:
        return True
    return str(update.effective_chat.id) == str(ALLOWED_CHAT_ID)


async def deny(update: Update):
    await update.message.reply_text("Доступ запрещён")


# ─── COMMANDS ────────────────────────────────────────

async def cmd_start(update: Update, _: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    await update.message.reply_text(
        "BugBounty Recon Bot\n\n"
        "Программы:\n"
        "/programs\n"
        "/add_program <имя>\n"
        "/del_program <имя>\n"
        "/list <программа>\n\n"
        "Домены:\n"
        "/add_domain <программа> <домен>\n"
        "/del_domain <программа> <домен>\n\n"
        "Заголовки (стелс):\n"
        "/add_header <программа> <ключ> <значение>\n"
        "  Пример: /add_header HackerOne X-Bug-Bounty myhandle\n"
        "/del_header <программа> <ключ>\n\n"
        "Сканирование:\n"
        "/scan <программа>\n"
        "/scan <программа> <домен>\n"
        "/status\n"
        "/stop <программа>"
    )


async def cmd_programs(update: Update, _: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    data  = load_data()
    progs = data.get("programs", {})
    if not progs:
        return await update.message.reply_text("Программ нет. Добавь: /add_program <имя>")
    lines = ["Bug Bounty программы:\n"]
    for name, prog in progs.items():
        nd  = len(prog.get("domains", []))
        nh  = len(prog.get("headers", {}))
        pfx = "[СКАН] " if name in active_scans else "  "
        lines.append(f"{pfx}{name}\n    {nd} доменов | {nh} заголовков")
    await update.message.reply_text("\n".join(lines))


async def cmd_add_program(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if not ctx.args:
        return await update.message.reply_text("Использование: /add_program <имя>")
    name = "_".join(ctx.args)
    data = load_data()
    if name in data["programs"]:
        return await update.message.reply_text(f"Программа {name!r} уже существует")
    data["programs"][name] = {
        "domains": [], "headers": {},
        "created": datetime.now().strftime("%Y-%m-%d")
    }
    save_data(data)
    await update.message.reply_text(
        f"Программа {name!r} создана\n"
        f"Добавь домены: /add_domain {name} target.com"
    )


async def cmd_del_program(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if not ctx.args:
        return await update.message.reply_text("Использование: /del_program <имя>")
    name = ctx.args[0]
    data = load_data()
    if name not in data["programs"]:
        return await update.message.reply_text(f"Программа {name!r} не найдена")
    del data["programs"][name]
    save_data(data)
    await update.message.reply_text(f"Программа {name!r} удалена")


async def cmd_list(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if not ctx.args:
        return await update.message.reply_text("Использование: /list <программа>")
    name = ctx.args[0]
    data = load_data()
    if name not in data["programs"]:
        return await update.message.reply_text(f"Программа {name!r} не найдена")
    prog    = data["programs"][name]
    domains = prog.get("domains", [])
    headers = prog.get("headers", {})
    sc_info = (
        f"СКАНИРУЮ: {active_scans[name].get('domain','?')}"
        if name in active_scans else "Не сканируется"
    )
    dom_txt = "\n".join(f"  - {d}" for d in domains) or "  нет"
    hdr_txt = "\n".join(f"  - {k}: {v}" for k, v in headers.items()) or "  нет"
    await update.message.reply_text(
        f"{name}\n"
        f"Создана: {prog.get('created', '?')}\n"
        f"Статус: {sc_info}\n\n"
        f"Домены ({len(domains)}):\n{dom_txt}\n\n"
        f"Заголовки ({len(headers)}):\n{hdr_txt}"
    )


async def cmd_add_domain(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if len(ctx.args) < 2:
        return await update.message.reply_text("Использование: /add_domain <программа> <домен>")
    name, domain = ctx.args[0], ctx.args[1].lower().strip()
    data = load_data()
    if name not in data["programs"]:
        return await update.message.reply_text(f"Программа {name!r} не найдена")
    if domain in data["programs"][name]["domains"]:
        return await update.message.reply_text(f"Домен {domain!r} уже добавлен")
    data["programs"][name]["domains"].append(domain)
    save_data(data)
    await update.message.reply_text(f"Домен {domain!r} добавлен в {name!r}")


async def cmd_del_domain(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if len(ctx.args) < 2:
        return await update.message.reply_text("Использование: /del_domain <программа> <домен>")
    name, domain = ctx.args[0], ctx.args[1].lower()
    data = load_data()
    if name not in data["programs"]:
        return await update.message.reply_text(f"Программа {name!r} не найдена")
    if domain not in data["programs"][name]["domains"]:
        return await update.message.reply_text(f"Домен {domain!r} не найден")
    data["programs"][name]["domains"].remove(domain)
    save_data(data)
    await update.message.reply_text(f"Домен {domain!r} удалён из {name!r}")


async def cmd_add_header(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if len(ctx.args) < 3:
        return await update.message.reply_text(
            "Использование: /add_header <программа> <ключ> <значение>\n"
            "Пример: /add_header HackerOne X-Bug-Bounty myhandle123"
        )
    name = ctx.args[0]
    key  = ctx.args[1]
    val  = " ".join(ctx.args[2:])
    data = load_data()
    if name not in data["programs"]:
        return await update.message.reply_text(f"Программа {name!r} не найдена")
    data["programs"][name]["headers"][key] = val
    save_data(data)
    await update.message.reply_text(f"Заголовок добавлен в {name!r}:\n{key}: {val}")


async def cmd_del_header(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if len(ctx.args) < 2:
        return await update.message.reply_text("Использование: /del_header <программа> <ключ>")
    name, key = ctx.args[0], ctx.args[1]
    data = load_data()
    if name not in data["programs"]:
        return await update.message.reply_text(f"Программа {name!r} не найдена")
    if key not in data["programs"][name].get("headers", {}):
        return await update.message.reply_text(f"Заголовок {key!r} не найден")
    del data["programs"][name]["headers"][key]
    save_data(data)
    await update.message.reply_text(f"Заголовок {key!r} удалён из {name!r}")


async def cmd_scan(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if not ctx.args:
        return await update.message.reply_text(
            "Использование:\n"
            "/scan <программа>         - все домены\n"
            "/scan <программа> <домен> - один домен"
        )
    name     = ctx.args[0]
    specific = ctx.args[1] if len(ctx.args) > 1 else None
    data     = load_data()
    if name not in data["programs"]:
        return await update.message.reply_text(f"Программа {name!r} не найдена")
    if name in active_scans:
        return await update.message.reply_text(
            f"Скан {name!r} уже запущен: {active_scans[name].get('domain', '?')}"
        )
    prog    = data["programs"][name]
    domains = [specific] if specific else prog.get("domains", [])
    headers = prog.get("headers", {})
    if not domains:
        return await update.message.reply_text(
            f"Нет доменов в {name!r}\n"
            f"Добавь: /add_domain {name} target.com"
        )
    if not RECON_SCRIPT.exists():
        return await update.message.reply_text(f"recon.sh не найден: {RECON_SCRIPT}")

    dom_str = "\n".join(f"  - {d}" for d in domains)
    hdr_str = "\n".join(f"  - {k}: {v}" for k, v in headers.items()) or "  нет"
    await update.message.reply_text(
        f"Запускаю {name!r}\n\n"
        f"Доменов: {len(domains)}\n{dom_str}\n\n"
        f"Заголовков: {len(headers)}\n{hdr_str}"
    )
    asyncio.create_task(_run_scans(update, name, domains, headers))


async def _run_scans(update: Update, program: str, domains: list, headers: dict):
    bot     = update.get_bot()
    chat_id = update.effective_chat.id
    for i, domain in enumerate(domains, 1):
        active_scans.setdefault(program, {})["domain"] = domain
        await bot.send_message(chat_id, f"[{i}/{len(domains)}] Сканирую: {domain}")
        header_args = []
        for k, v in headers.items():
            header_args += ["--extra-header", f"{k}: {v}"]
        cmd = ["/bin/bash", str(RECON_SCRIPT), "-d", domain] + header_args
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            active_scans[program]["proc"] = proc
            try:
                await asyncio.wait_for(proc.wait(), timeout=10800)
            except asyncio.TimeoutError:
                proc.kill()
                await bot.send_message(chat_id, f"Таймаут 3ч для {domain}, остановлено")
        except Exception as e:
            await bot.send_message(chat_id, f"Ошибка при сканировании {domain}: {e}")
    active_scans.pop(program, None)
    await bot.send_message(
        chat_id,
        f"Сканирование {program!r} завершено!\n"
        f"Доменов: {len(domains)}\n"
        f"Результаты: ~/recon-results/"
    )


async def cmd_status(update: Update, _: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if not active_scans:
        return await update.message.reply_text("Активных сканирований нет")
    lines = ["Активные сканирования:\n"]
    for name, info in active_scans.items():
        proc = info.get("proc")
        pid  = proc.pid if proc else "?"
        lines.append(f"- {name}: {info.get('domain','?')} (PID: {pid})")
    await update.message.reply_text("\n".join(lines))


async def cmd_stop(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not allowed(update):
        return await deny(update)
    if not ctx.args:
        return await update.message.reply_text("Использование: /stop <программа>")
    name = ctx.args[0]
    if name not in active_scans:
        return await update.message.reply_text(f"Нет активного скана для {name!r}")
    info = active_scans.pop(name, {})
    proc = info.get("proc")
    if proc:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
    await update.message.reply_text(f"Скан {name!r} остановлен")


# ─── MAIN ─────────────────────────────────────────────

def main():
    if not BOT_TOKEN:
        print("Заполни BOT_TOKEN в bot.py (строка 38)")
        sys.exit(1)
    if not ALLOWED_CHAT_ID:
        print("ВНИМАНИЕ: ALLOWED_CHAT_ID не задан — бот доступен всем!")
    else:
        print(f"Доступ ограничен: chat_id = {ALLOWED_CHAT_ID}")
    if not RECON_SCRIPT.exists():
        print(f"ВНИМАНИЕ: recon.sh не найден: {RECON_SCRIPT}")
    print(f"Данные программ: {DATA_FILE}")
    print("Бот запущен... Ctrl+C для остановки")

    app = Application.builder().token(BOT_TOKEN).build()
    handlers = [
        ("start",       cmd_start),
        ("help",        cmd_start),
        ("programs",    cmd_programs),
        ("add_program", cmd_add_program),
        ("del_program", cmd_del_program),
        ("list",        cmd_list),
        ("add_domain",  cmd_add_domain),
        ("del_domain",  cmd_del_domain),
        ("add_header",  cmd_add_header),
        ("del_header",  cmd_del_header),
        ("scan",        cmd_scan),
        ("status",      cmd_status),
        ("stop",        cmd_stop),
    ]
    for cmd, func in handlers:
        app.add_handler(CommandHandler(cmd, func))
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
