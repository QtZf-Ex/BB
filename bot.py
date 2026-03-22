#!/usr/bin/env python3
"""
BugBounty Recon Bot v1.0

Функции:
  - Управление программами bug bounty (группы доменов)
  - Добавление/удаление доменов через Telegram
  - Настройка HTTP заголовков на программу (Authorization, X-Bug-Bounty...)
  - Настройка rate limit на программу
  - Запуск/остановка сканирований
  - Получение отчётов в Telegram

Установка:
  pip install python-telegram-bot --break-system-packages

Запуск:
  python3 bot.py
  # или с токеном через env:
  RECON_BOT_TOKEN=xxx python3 bot.py
"""

import asyncio
import json
import logging
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

try:
    from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
    from telegram.ext import (
        Application, CommandHandler, CallbackQueryHandler,
        ConversationHandler, MessageHandler, filters, ContextTypes
    )
except ImportError:
    print("ERROR: python-telegram-bot не установлен!")
    print("Установи: pip install python-telegram-bot --break-system-packages")
    sys.exit(1)

# =================================================================
#  НАСТРОЙКИ — ЗАПОЛНИ ЗДЕСЬ
# =================================================================
BOT_TOKEN = os.getenv("RECON_BOT_TOKEN", "")  # <- или вставь токен сюда

# ID пользователей с доступом к боту.
# Оставь пустым [] чтобы разрешить всем (только для тестов!)
# Получить свой ID: @userinfobot в Telegram
AUTHORIZED_USERS: list[int] = []  # <- например [123456789, 987654321]
# =================================================================

CONFIG_DIR   = Path.home() / ".config" / "recon"
PROGRAMS_FILE = CONFIG_DIR / "programs.json"
RECON_SCRIPT  = Path(__file__).parent / "recon.sh"
RESULTS_DIR   = Path.home() / "recon-results"

logging.basicConfig(
    format="%(asctime)s | %(levelname)s | %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# =================================================================
# States для ConversationHandler
# =================================================================
(
    ST_MAIN, ST_PROG, ST_ADD_PROG, ST_ADD_DOMAIN,
    ST_ADD_HDR_KEY, ST_ADD_HDR_VAL, ST_SET_RATE
) = range(7)

# Активные сканирования: ключ "prog:domain" -> asyncio.subprocess
_active_scans: dict = {}


# =================================================================
# CONFIG
# =================================================================
def _load() -> dict:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if PROGRAMS_FILE.exists():
        try:
            return json.loads(PROGRAMS_FILE.read_text())
        except Exception:
            pass
    return {"programs": {}}


def _save(cfg: dict):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    PROGRAMS_FILE.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))


def get_prog(name: str) -> Optional[dict]:
    return _load()["programs"].get(name)


def is_auth(uid: int) -> bool:
    if not AUTHORIZED_USERS:
        return True  # dev-mode: все разрешены
    return uid in AUTHORIZED_USERS


def _default_prog() -> dict:
    return {
        "domains": [],
        "headers": {},
        "rate_limit": 30,
        "created": datetime.now().isoformat()
    }


# =================================================================
# KEYBOARDS
# =================================================================
def kb_main() -> InlineKeyboardMarkup:
    cfg = _load()
    progs = cfg.get("programs", {})
    rows = []
    for name in sorted(progs):
        n_dom = len(progs[name].get("domains", []))
        n_hdr = len(progs[name].get("headers", {}))
        scanning = any(k.startswith(f"{name}:") for k in _active_scans)
        icon = "🔄" if scanning else "📁"
        rows.append([InlineKeyboardButton(
            f"{icon} {name}  ({n_dom}d / {n_hdr}h)",
            callback_data=f"P:{name}"
        )])
    rows.append([
        InlineKeyboardButton("➕ Новая программа", callback_data="NEW"),
        InlineKeyboardButton("🔄 Скан всего",     callback_data="ALL"),
    ])
    return InlineKeyboardMarkup(rows)


def kb_prog(name: str) -> InlineKeyboardMarkup:
    scanning = any(k.startswith(f"{name}:") for k in _active_scans)
    scan_btn = InlineKeyboardButton(
        "⏹ Стоп", callback_data=f"STOP:{name}"
    ) if scanning else InlineKeyboardButton(
        "▶️ Скан", callback_data=f"SCAN:{name}"
    )
    return InlineKeyboardMarkup([
        [scan_btn],
        [
            InlineKeyboardButton("🌐 Домены",    callback_data=f"DOM:{name}"),
            InlineKeyboardButton("🔑 Заголовки", callback_data=f"HDR:{name}"),
        ],
        [
            InlineKeyboardButton("⚡️ Rate limit",  callback_data=f"RATE:{name}"),
            InlineKeyboardButton("🗑 Удалить прог", callback_data=f"DELPROG:{name}"),
        ],
        [InlineKeyboardButton("◀️ Назад", callback_data="BACK")],
    ])


def kb_domains(name: str) -> InlineKeyboardMarkup:
    prog = get_prog(name) or {}
    rows = []
    for d in sorted(prog.get("domains", [])):
        rows.append([
            InlineKeyboardButton(f"🌐 {d}", callback_data="NOP"),
            InlineKeyboardButton("❌",      callback_data=f"DELD:{name}:{d}"),
        ])
    rows.append([
        InlineKeyboardButton("➕ Добавить домен", callback_data=f"ADDD:{name}"),
        InlineKeyboardButton("◀️ Назад",          callback_data=f"P:{name}"),
    ])
    return InlineKeyboardMarkup(rows)


def kb_headers(name: str) -> InlineKeyboardMarkup:
    prog = get_prog(name) or {}
    rows = []
    for k, v in sorted(prog.get("headers", {}).items()):
        short = v[:25] + "..." if len(v) > 25 else v
        rows.append([
            InlineKeyboardButton(f"{k}: {short}", callback_data="NOP"),
            InlineKeyboardButton("❌", callback_data=f"DELH:{name}:{k}"),
        ])
    rows.append([
        InlineKeyboardButton("➕ Добавить заголовок", callback_data=f"ADDH:{name}"),
        InlineKeyboardButton("◀️ Назад",              callback_data=f"P:{name}"),
    ])
    return InlineKeyboardMarkup(rows)


# =================================================================
# SCAN
# =================================================================
def _make_headers_file(prog_name: str, headers: dict) -> Optional[str]:
    """Записать заголовки в файл. Вернуть путь или None."""
    if not headers:
        return None
    hf = CONFIG_DIR / f"headers_{prog_name}.txt"
    hf.write_text("\n".join(f"{k}: {v}" for k, v in headers.items()))
    return str(hf)


async def _run_scan(prog_name: str, domain: str,
                   context: ContextTypes.DEFAULT_TYPE, chat_id: int):
    prog = get_prog(prog_name) or {}
    headers_file = _make_headers_file(prog_name, prog.get("headers", {}))
    rate = prog.get("rate_limit", 30)

    cmd = [
        "bash", str(RECON_SCRIPT),
        "-d", domain,
        "-o", str(RESULTS_DIR),
        "-t", str(rate),
    ]
    if headers_file:
        cmd += ["--headers-file", headers_file]

    key = f"{prog_name}:{domain}"
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        _active_scans[key] = proc
        await proc.wait()
        _active_scans.pop(key, None)
    except Exception as e:
        _active_scans.pop(key, None)
        logger.error(f"Scan error {domain}: {e}")
        try:
            await context.bot.send_message(
                chat_id=chat_id,
                text=f"❌ Ошибка скана <code>{domain}</code>: {e}",
                parse_mode="HTML"
            )
        except Exception:
            pass


# =================================================================
# HANDLERS
# =================================================================
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if not is_auth(user.id):
        await update.message.reply_text("❌ Нет доступа")
        return ConversationHandler.END
    await update.message.reply_text(
        f"<b>BugBounty Recon Bot</b>\n"
        f"Привет, {user.first_name}!\n\n"
        f"Управляй программами bug bounty и запускай сканирования.",
        parse_mode="HTML",
        reply_markup=kb_main()
    )
    return ST_MAIN


async def show_main(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    cfg = _load()
    total_d = sum(len(p.get("domains", [])) for p in cfg["programs"].values())
    total_h = sum(len(p.get("headers", {})) for p in cfg["programs"].values())
    await q.edit_message_text(
        f"<b>Программы Bug Bounty</b>\n"
        f"Программ: {len(cfg['programs'])}  |  Доменов: {total_d}  |  Заголовков: {total_h}\n\n"
        f"Выбери программу:",
        parse_mode="HTML",
        reply_markup=kb_main()
    )
    return ST_MAIN


async def show_prog(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    prog = get_prog(name)
    if not prog:
        await q.edit_message_text("❌ Не найдено", reply_markup=kb_main())
        return ST_MAIN
    scanning = any(k.startswith(f"{name}:") for k in _active_scans)
    status = "🔄 Сканирование..." if scanning else "⚪️ Готово"
    doms = prog.get("domains", [])
    hdrs = prog.get("headers", {})
    rate = prog.get("rate_limit", 30)
    text = (
        f"<b>{name}</b>\n\n"
        f"Статус: {status}\n"
        f"Доменов: {len(doms)}\n"
        f"Заголовков: {len(hdrs)}\n"
        f"Rate limit: {rate} req/s\n"
    )
    if doms:
        text += "\nДомены:\n" + "\n".join(f"  • {d}" for d in sorted(doms)[:8])
        if len(doms) > 8:
            text += f"\n  ... и ещё {len(doms)-8}"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_prog(name))
    return ST_PROG


# ── New program ──────────────────────────────────────
async def start_new_prog(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    await q.edit_message_text(
        "<b>Новая программа</b>\n\nВведи название:\n"
        "<i>Пример: hackerone_company  /  bugcrowd_target</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("❌ Отмена", callback_data="BACK")]])
    )
    return ST_ADD_PROG


async def handle_new_prog(update: Update, context: ContextTypes.DEFAULT_TYPE):
    name = update.message.text.strip().replace(" ", "_")
    if not name or len(name) > 60:
        await update.message.reply_text("❌ Неверное название")
        return ST_ADD_PROG
    cfg = _load()
    if name in cfg["programs"]:
        await update.message.reply_text(f"❌ '{name}' уже существует")
        return ST_ADD_PROG
    cfg["programs"][name] = _default_prog()
    _save(cfg)
    context.user_data["prog"] = name
    await update.message.reply_text(
        f"✅ Программа <b>{name}</b> создана!\nТеперь добавь домены:",
        parse_mode="HTML",
        reply_markup=kb_prog(name)
    )
    return ST_PROG


# ── Domains ──────────────────────────────────────────
async def show_domains(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    prog = get_prog(name) or {}
    doms = prog.get("domains", [])
    text = f"<b>Домены — {name}</b>\n\n"
    text += "\n".join(f"• {d}" for d in sorted(doms)) if doms else "<i>Нет доменов</i>"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_domains(name))
    return ST_PROG


async def start_add_domain(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    await q.edit_message_text(
        f"<b>Добавить домен</b> в {name}\n\n"
        "Введи домен (без https://):\n<i>Пример: target.com</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Назад", callback_data=f"DOM:{name}")]])
    )
    return ST_ADD_DOMAIN


async def handle_add_domain(update: Update, context: ContextTypes.DEFAULT_TYPE):
    raw = update.message.text.strip().lower()
    domain = raw.replace("https://","").replace("http://","").strip("/")
    name = context.user_data.get("prog")
    if not domain or "." not in domain or not name:
        await update.message.reply_text("❌ Неверный домен")
        return ST_ADD_DOMAIN
    cfg = _load()
    if domain in cfg["programs"][name]["domains"]:
        await update.message.reply_text(f"⚠️ {domain} уже добавлен")
    else:
        cfg["programs"][name]["domains"].append(domain)
        _save(cfg)
        await update.message.reply_text(f"✅ <code>{domain}</code> добавлен", parse_mode="HTML")
    doms = cfg["programs"][name]["domains"]
    text = f"<b>Домены — {name}</b>\n\n" + "\n".join(f"• {d}" for d in sorted(doms))
    await update.message.reply_text(text, parse_mode="HTML", reply_markup=kb_domains(name))
    return ST_PROG


async def del_domain(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    _, name, domain = q.data.split(":", 2)
    cfg = _load()
    if name in cfg["programs"] and domain in cfg["programs"][name]["domains"]:
        cfg["programs"][name]["domains"].remove(domain)
        _save(cfg)
    doms = (get_prog(name) or {}).get("domains", [])
    text = f"<b>Домены — {name}</b>\n\n"
    text += "\n".join(f"• {d}" for d in sorted(doms)) if doms else "<i>Нет доменов</i>"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_domains(name))
    return ST_PROG


# ── Headers ──────────────────────────────────────────
async def show_headers(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    prog = get_prog(name) or {}
    hdrs = prog.get("headers", {})
    text = f"<b>Заголовки — {name}</b>\n\n"
    if hdrs:
        for k, v in sorted(hdrs.items()):
            short = v[:40] + "..." if len(v) > 40 else v
            text += f"<code>{k}</code>: {short}\n"
    else:
        text += (
            "<i>Нет заголовков</i>\n\n"
            "Примеры:\n"
            "<code>Authorization: Bearer xxxxxxxx</code>\n"
            "<code>X-Bug-Bounty: @username</code>\n"
            "<code>Cookie: session=abc123</code>"
        )
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_headers(name))
    return ST_PROG


async def start_add_header(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    await q.edit_message_text(
        f"<b>Новый заголовок</b> для {name}\n\n"
        "Введи имя заголовка:\n"
        "<i>Пример: Authorization</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Отмена", callback_data=f"HDR:{name}")]])
    )
    return ST_ADD_HDR_KEY


async def handle_hdr_key(update: Update, context: ContextTypes.DEFAULT_TYPE):
    key = update.message.text.strip()
    if not key or ":" in key:
        await update.message.reply_text("❌ Неверное имя (без двоеточия)")
        return ST_ADD_HDR_KEY
    context.user_data["hdr_key"] = key
    await update.message.reply_text(
        f"Заголовок: <code>{key}</code>\n\nТеперь введи значение:",
        parse_mode="HTML"
    )
    return ST_ADD_HDR_VAL


async def handle_hdr_val(update: Update, context: ContextTypes.DEFAULT_TYPE):
    val  = update.message.text.strip()
    name = context.user_data.get("prog")
    key  = context.user_data.get("hdr_key")
    if not val or not name or not key:
        await update.message.reply_text("❌ Ошибка")
        return ST_PROG
    cfg = _load()
    cfg["programs"][name]["headers"][key] = val
    _save(cfg)
    await update.message.reply_text(
        f"✅ Заголовок добавлен:\n<code>{key}: {val[:60]}</code>",
        parse_mode="HTML",
        reply_markup=kb_headers(name)
    )
    return ST_PROG


async def del_header(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    _, name, key = q.data.split(":", 2)
    cfg = _load()
    cfg["programs"][name]["headers"].pop(key, None)
    _save(cfg)
    hdrs = (get_prog(name) or {}).get("headers", {})
    text = f"<b>Заголовки — {name}</b>\n\n"
    for k, v in sorted(hdrs.items()):
        text += f"<code>{k}</code>: {v[:40]}\n"
    if not hdrs:
        text += "<i>Нет заголовков</i>"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_headers(name))
    return ST_PROG


# ── Rate limit ───────────────────────────────────────
async def show_rate(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    prog = get_prog(name) or {}
    rate = prog.get("rate_limit", 30)
    await q.edit_message_text(
        f"<b>Rate limit — {name}</b>\n\n"
        f"Текущий: <b>{rate}</b> req/s\n\n"
        f"Введи новое значение (1-150):\n"
        f"<i>Осторожно: высокий rate может заблокировать тебя на программе!</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Назад", callback_data=f"P:{name}")]])
    )
    return ST_SET_RATE


async def handle_rate(update: Update, context: ContextTypes.DEFAULT_TYPE):
    name = context.user_data.get("prog")
    try:
        rate = int(update.message.text.strip())
        rate = max(1, min(150, rate))
    except Exception:
        await update.message.reply_text("❌ Введи число от 1 до 150")
        return ST_SET_RATE
    cfg = _load()
    if name in cfg["programs"]:
        cfg["programs"][name]["rate_limit"] = rate
        _save(cfg)
    await update.message.reply_text(
        f"✅ Rate limit: <b>{rate}</b> req/s",
        parse_mode="HTML",
        reply_markup=kb_prog(name)
    )
    return ST_PROG


# ── Scan ─────────────────────────────────────────────
async def start_scan(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    prog = get_prog(name)
    if not prog or not prog.get("domains"):
        await q.answer("⚠️ Нет доменов!", show_alert=True)
        return ST_PROG
    doms = prog["domains"]
    chat_id = q.message.chat_id
    await q.edit_message_text(
        f"▶️ <b>Скан запущен — {name}</b>\n\n"
        f"Доменов: {len(doms)}\n"
        f"Rate: {prog.get('rate_limit',30)} req/s\n"
        f"Заголовков: {len(prog.get('headers',{}))}\n\n"
        f"Результаты придут в Telegram по завершении каждого домена.",
        parse_mode="HTML",
        reply_markup=kb_prog(name)
    )
    for d in doms:
        asyncio.create_task(_run_scan(name, d, context, chat_id))
    return ST_PROG


async def stop_scan(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    to_stop = [k for k in list(_active_scans) if k.startswith(f"{name}:")]
    for k in to_stop:
        proc = _active_scans.pop(k, None)
        if proc:
            try:
                proc.terminate()
            except Exception:
                pass
    await q.answer(f"⏹ Остановлено: {len(to_stop)}", show_alert=True)
    return ST_PROG


async def scan_all(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    cfg = _load()
    progs = cfg.get("programs", {})
    if not progs:
        await q.answer("⚠️ Нет программ", show_alert=True)
        return ST_MAIN
    chat_id = q.message.chat_id
    total = sum(len(p.get("domains",[])) for p in progs.values())
    await q.edit_message_text(
        f"🔄 <b>Полное сканирование</b>\n\n"
        f"Программ: {len(progs)}\n"
        f"Доменов всего: {total}\n\n"
        f"⏳ Результаты придут в Telegram...",
        parse_mode="HTML",
        reply_markup=kb_main()
    )
    for pname, prog in progs.items():
        for d in prog.get("domains", []):
            asyncio.create_task(_run_scan(pname, d, context, chat_id))
    return ST_MAIN


async def del_prog(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    await q.edit_message_text(
        f"🗑 <b>Удалить '{name}'?</b>\n\nВсе домены и заголовки будут удалены.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[
            InlineKeyboardButton("✅ Да",   callback_data=f"CONFIRMDEL:{name}"),
            InlineKeyboardButton("❌ Нет",  callback_data=f"P:{name}"),
        ]])
    )
    return ST_PROG


async def confirm_del_prog(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    cfg = _load()
    cfg["programs"].pop(name, None)
    _save(cfg)
    await q.edit_message_text(
        f"✅ Программа <b>{name}</b> удалена",
        parse_mode="HTML",
        reply_markup=kb_main()
    )
    return ST_MAIN


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_auth(update.effective_user.id):
        return
    if not _active_scans:
        await update.message.reply_text("✅ Нет активных сканирований")
        return
    lines = [f"🔄 <b>Активные сканы ({len(_active_scans)}):</b>"]
    for k in sorted(_active_scans):
        prog, domain = k.split(":", 1)
        lines.append(f"  • <b>{prog}</b>: <code>{domain}</code>")
    await update.message.reply_text("\n".join(lines), parse_mode="HTML")


async def nop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.callback_query:
        await update.callback_query.answer()


async def err_handler(update: object, context: ContextTypes.DEFAULT_TYPE):
    logger.error(f"Error: {context.error}", exc_info=context.error)


# =================================================================
# MAIN
# =================================================================
def main():
    token = BOT_TOKEN or os.getenv("RECON_BOT_TOKEN", "")
    if not token:
        print("ERROR: BOT_TOKEN не задан!")
        print("Заполни BOT_TOKEN в bot.py (строка ~29)")
        print("Или: RECON_BOT_TOKEN=xxxx python3 bot.py")
        sys.exit(1)

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    app = Application.builder().token(token).build()

    conv = ConversationHandler(
        entry_points=[
            CommandHandler("start", cmd_start),
            CommandHandler("menu",  cmd_start),
        ],
        states={
            ST_MAIN: [
                CallbackQueryHandler(show_prog,      pattern=r"^P:"),
                CallbackQueryHandler(start_new_prog, pattern=r"^NEW$"),
                CallbackQueryHandler(scan_all,        pattern=r"^ALL$"),
                CallbackQueryHandler(show_main,       pattern=r"^BACK$"),
            ],
            ST_PROG: [
                CallbackQueryHandler(show_main,       pattern=r"^BACK$"),
                CallbackQueryHandler(show_prog,       pattern=r"^P:"),
                CallbackQueryHandler(show_domains,    pattern=r"^DOM:"),
                CallbackQueryHandler(show_headers,    pattern=r"^HDR:"),
                CallbackQueryHandler(show_rate,       pattern=r"^RATE:"),
                CallbackQueryHandler(start_add_domain,pattern=r"^ADDD:"),
                CallbackQueryHandler(del_domain,      pattern=r"^DELD:"),
                CallbackQueryHandler(start_add_header,pattern=r"^ADDH:"),
                CallbackQueryHandler(del_header,      pattern=r"^DELH:"),
                CallbackQueryHandler(start_scan,      pattern=r"^SCAN:"),
                CallbackQueryHandler(stop_scan,       pattern=r"^STOP:"),
                CallbackQueryHandler(del_prog,        pattern=r"^DELPROG:"),
                CallbackQueryHandler(confirm_del_prog,pattern=r"^CONFIRMDEL:"),
                CallbackQueryHandler(nop,             pattern=r"^NOP$"),
            ],
            ST_ADD_PROG:  [MessageHandler(filters.TEXT & ~filters.COMMAND, handle_new_prog),
                           CallbackQueryHandler(show_main, pattern=r"^BACK$")],
            ST_ADD_DOMAIN:[MessageHandler(filters.TEXT & ~filters.COMMAND, handle_add_domain),
                           CallbackQueryHandler(show_domains, pattern=r"^DOM:")],
            ST_ADD_HDR_KEY:[MessageHandler(filters.TEXT & ~filters.COMMAND, handle_hdr_key),
                            CallbackQueryHandler(show_headers, pattern=r"^HDR:")],
            ST_ADD_HDR_VAL:[MessageHandler(filters.TEXT & ~filters.COMMAND, handle_hdr_val)],
            ST_SET_RATE:   [MessageHandler(filters.TEXT & ~filters.COMMAND, handle_rate),
                            CallbackQueryHandler(show_prog, pattern=r"^P:")],
        },
        fallbacks=[
            CommandHandler("start",  cmd_start),
            CommandHandler("status", cmd_status),
        ],
    )

    app.add_handler(conv)
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_error_handler(err_handler)

    print("BugBounty Recon Bot запущен!")
    print(f"Config:  {PROGRAMS_FILE}")
    print(f"Script:  {RECON_SCRIPT}")
    print(f"Auth:    {'ALL USERS (dev mode)' if not AUTHORIZED_USERS else AUTHORIZED_USERS}")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
