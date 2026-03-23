#!/usr/bin/env python3
"""
BugBounty Recon Bot v2.1

FIX v2.1:
  - drop_pending_updates=True: не обрабатывать старые апдейты после рестарта
  - Глобальный обработчик потерянных callback_query (кнопки от старых сессий)
  - Команда /kill для остановки зависших сканов
  - Явная инструкция при старте: как убить старый процесс бота

Установка:
  pip install python-telegram-bot apscheduler --break-system-packages

Запуск:
  # ВАЖНО: убить старый процесс перед запуском!
  pkill -f bot.py
  python3 bot.py
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
    print("ERROR: pip install python-telegram-bot --break-system-packages")
    sys.exit(1)

try:
    from apscheduler.schedulers.asyncio import AsyncIOScheduler
    HAS_SCHEDULER = True
except ImportError:
    HAS_SCHEDULER = False
    print("INFO: apscheduler нет — cron недоступен")
    print("      pip install apscheduler --break-system-packages")

# =================================================================
#  НАСТРОЙКИ
# =================================================================
BOT_TOKEN = os.getenv("RECON_BOT_TOKEN", "")  # <- или вставь токен сюда

# Получи свой ID: написать @userinfobot в Telegram
AUTHORIZED_USERS: list = []  # <- напр: [123456789]
# =================================================================

CONFIG_DIR    = Path.home() / ".config" / "recon"
PROGRAMS_FILE = CONFIG_DIR / "programs.json"
CRON_FILE     = CONFIG_DIR / "cron.json"
RECON_SCRIPT  = Path(__file__).parent / "recon.sh"
RESULTS_DIR   = Path.home() / "recon-results"

logging.basicConfig(
    format="%(asctime)s | %(levelname)s | %(message)s",
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# States
(
    ST_MAIN, ST_PROG, ST_ADD_PROG, ST_ADD_DOMAIN,
    ST_ADD_HDR_KEY, ST_ADD_HDR_VAL, ST_SET_RATE, ST_SET_CRON
) = range(8)

_active_scans: dict = {}
scheduler: Optional[object] = None


# =================================================================
# CONFIG
# =================================================================
def _load() -> dict:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if PROGRAMS_FILE.exists():
        try: return json.loads(PROGRAMS_FILE.read_text())
        except: pass
    return {"programs": {}}

def _save(cfg: dict):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    PROGRAMS_FILE.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))

def _load_cron() -> dict:
    if CRON_FILE.exists():
        try: return json.loads(CRON_FILE.read_text())
        except: pass
    return {}

def _save_cron(data: dict):
    CRON_FILE.write_text(json.dumps(data, indent=2))

def get_prog(name: str) -> Optional[dict]:
    return _load()["programs"].get(name)

def is_auth(uid: int) -> bool:
    return not AUTHORIZED_USERS or uid in AUTHORIZED_USERS

def _default_prog() -> dict:
    return {"domains": [], "headers": {}, "rate_limit": 30,
            "created": datetime.now().isoformat()}


# =================================================================
# KEYBOARDS
# =================================================================
def kb_main() -> InlineKeyboardMarkup:
    cfg = _load()
    progs = cfg.get("programs", {})
    rows = []
    for name in sorted(progs):
        p = progs[name]
        n_dom = len(p.get("domains", []))
        scanning = any(k.startswith(f"{name}:") for k in _active_scans)
        icon = "🔄" if scanning else "📁"
        rows.append([InlineKeyboardButton(
            f"{icon} {name}  ({n_dom} дом.)", callback_data=f"P:{name}"
        )])
    rows.append([InlineKeyboardButton("➕ Новая программа", callback_data="NEW")])
    rows.append([
        InlineKeyboardButton("▶️ Скан всего", callback_data="ALL"),
        InlineKeyboardButton("🕐 Cron",       callback_data="CRONMENU"),
    ])
    return InlineKeyboardMarkup(rows)


def kb_prog(name: str) -> InlineKeyboardMarkup:
    scanning = any(k.startswith(f"{name}:") for k in _active_scans)
    scan_btn = InlineKeyboardButton(
        "⏹ Стоп", callback_data=f"STOP:{name}"
    ) if scanning else InlineKeyboardButton(
        "▶️ Скан", callback_data=f"SCAN:{name}"
    )
    prog = get_prog(name) or {}
    n_dom = len(prog.get("domains", []))
    note = " ⚠️" if n_dom == 0 else f" ({n_dom})"
    return InlineKeyboardMarkup([
        [scan_btn],
        [
            InlineKeyboardButton(f"🌐 Домены{note}", callback_data=f"DOM:{name}"),
            InlineKeyboardButton("🔑 Заголовки",     callback_data=f"HDR:{name}"),
        ],
        [
            InlineKeyboardButton("⚡ Rate limit",   callback_data=f"RATE:{name}"),
            InlineKeyboardButton("🗑 Удалить",       callback_data=f"DELPROG:{name}"),
        ],
        [InlineKeyboardButton("◀️ Назад", callback_data="BACK")],
    ])


def kb_domains(name: str) -> InlineKeyboardMarkup:
    prog = get_prog(name) or {}
    rows = []
    for d in sorted(prog.get("domains", [])):
        rows.append([
            InlineKeyboardButton(f"🌐 {d}", callback_data="NOP"),
            InlineKeyboardButton("❌", callback_data=f"DELD:{name}:{d}"),
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
        InlineKeyboardButton("➕ Добавить", callback_data=f"ADDH:{name}"),
        InlineKeyboardButton("◀️ Назад",   callback_data=f"P:{name}"),
    ])
    return InlineKeyboardMarkup(rows)


def kb_cron() -> InlineKeyboardMarkup:
    cron_data = _load_cron()
    cfg = _load()
    rows = []
    for name in sorted(cfg.get("programs", {})):
        schedule = cron_data.get(name, {})
        if schedule:
            h = schedule.get("interval_hours", "?")
            rows.append([InlineKeyboardButton(
                f"🕐 {name} — каждые {h}ч (нажми чтобы отключить)",
                callback_data=f"CRONDEL:{name}"
            )])
        else:
            rows.append([InlineKeyboardButton(
                f"⚫ {name} — нет расписания",
                callback_data=f"CRONSET:{name}"
            )])
    rows.append([InlineKeyboardButton("◀️ Назад", callback_data="BACK")])
    return InlineKeyboardMarkup(rows)


# =================================================================
# SCAN
# =================================================================
def _make_headers_file(prog_name: str, headers: dict) -> Optional[str]:
    if not headers: return None
    hf = CONFIG_DIR / f"headers_{prog_name}.txt"
    hf.write_text("\n".join(f"{k}: {v}" for k, v in headers.items()))
    return str(hf)


async def _run_scan(prog_name: str, domain: str,
                    context: ContextTypes.DEFAULT_TYPE, chat_id: int):
    prog = get_prog(prog_name) or {}
    headers_file = _make_headers_file(prog_name, prog.get("headers", {}))
    rate = prog.get("rate_limit", 30)
    cmd = ["bash", str(RECON_SCRIPT), "-d", domain,
           "-o", str(RESULTS_DIR), "-t", str(rate)]
    if headers_file: cmd += ["--headers-file", headers_file]
    key = f"{prog_name}:{domain}"
    try:
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"▶️ Старт: <code>{domain}</code>", parse_mode="HTML")
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL)
        _active_scans[key] = proc
        await proc.wait()
        _active_scans.pop(key, None)
    except Exception as e:
        _active_scans.pop(key, None)
        logger.error(f"Scan error {domain}: {e}")
        try:
            await context.bot.send_message(
                chat_id=chat_id,
                text=f"❌ Ошибка: <code>{domain}</code> — {e}", parse_mode="HTML")
        except: pass


# =================================================================
# HANDLERS
# =================================================================
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if not is_auth(user.id):
        await update.message.reply_text("❌ Нет доступа")
        return ConversationHandler.END
    cfg = _load()
    progs = cfg.get("programs", {})
    total_d = sum(len(p.get("domains", [])) for p in progs.values())
    text = (
        f"<b>🕷️ BugBounty Recon Bot v2.1</b>\n"
        f"Привет, {user.first_name}!\n\n"
        f"📁 Программ: {len(progs)}  |  🌐 Доменов: {total_d}\n"
        f"🔄 Активных сканов: {len(_active_scans)}\n\n"
        f"<b>Как добавить домены:</b>\n"
        f"1️⃣ ➕ Новая программа → введи название\n"
        f"2️⃣ Программа → 🌐 Домены → ➕ Добавить домен\n"
        f"3️⃣ Введи домен: <code>target.com</code>\n"
        f"4️⃣ ▶️ Скан\n\n"
        f"Выбери программу:"
    )
    await update.message.reply_text(
        text, parse_mode="HTML", reply_markup=kb_main()
    )
    return ST_MAIN


async def show_main(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    cfg = _load()
    progs = cfg.get("programs", {})
    total_d = sum(len(p.get("domains", [])) for p in progs.values())
    await q.edit_message_text(
        f"<b>Программы Bug Bounty</b>\n"
        f"Программ: {len(progs)}  |  Доменов: {total_d}  |  Активных: {len(_active_scans)}\n\n"
        f"Выбери программу:",
        parse_mode="HTML", reply_markup=kb_main()
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
    doms = prog.get("domains", [])
    cron = _load_cron().get(name, {})
    text = (
        f"<b>📁 {name}</b>\n\n"
        f"Статус: {'🔄 Сканируется...' if scanning else '⚫ Готово'}\n"
        f"Доменов: <b>{len(doms)}</b>\n"
        f"Заголовков: {len(prog.get('headers', {}))}\n"
        f"Rate: {prog.get('rate_limit', 30)} req/s\n"
        f"Cron: {cron.get('interval_hours', 'нет')}ч\n"
    )
    if doms:
        text += "\n<b>Домены:</b>\n" + "\n".join(f"  • {d}" for d in sorted(doms)[:10])
        if len(doms) > 10: text += f"\n  ... +{len(doms)-10}"
    else:
        text += "\n⚠️ <b>Нет доменов!</b>\nНажми 🌐 Домены → ➕ Добавить домен"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_prog(name))
    return ST_PROG


async def start_new_prog(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    await q.edit_message_text(
        "<b>➕ Новая программа Bug Bounty</b>\n\n"
        "Введи название:\n"
        "<i>Пример: hackerone_company, bugcrowd_target</i>",
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
        f"✅ Программа <b>{name}</b> создана!\n\n"
        f"Теперь добавь домены.\nВведи домен (без https://):\n"
        f"<i>Пример: target.com</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("⏭ Пропустить", callback_data=f"P:{name}")]])
    )
    return ST_ADD_DOMAIN


async def show_domains(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    prog = get_prog(name) or {}
    doms = prog.get("domains", [])
    text = f"<b>🌐 Домены — {name}</b>\n\n"
    text += ("\n".join(f"• {d}" for d in sorted(doms))) if doms else "<i>Нет доменов</i>"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_domains(name))
    return ST_PROG


async def start_add_domain(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    await q.edit_message_text(
        f"<b>➕ Добавить домен в {name}</b>\n\n"
        f"Введи домен (без https://):\n"
        f"<i>Пример: target.com</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Назад", callback_data=f"DOM:{name}")]])
    )
    return ST_ADD_DOMAIN


async def handle_add_domain(update: Update, context: ContextTypes.DEFAULT_TYPE):
    raw = update.message.text.strip().lower()
    domain = raw.replace("https://","").replace("http://","").strip("/")
    name = context.user_data.get("prog")
    if not domain or "." not in domain or not name:
        await update.message.reply_text("❌ Неверный домен (напр. target.com)")
        return ST_ADD_DOMAIN
    cfg = _load()
    if name not in cfg["programs"]:
        await update.message.reply_text("❌ Программа не найдена")
        return ST_MAIN
    if domain in cfg["programs"][name]["domains"]:
        await update.message.reply_text(f"⚠️ {domain} уже добавлен",
                                         reply_markup=kb_domains(name))
        return ST_PROG
    cfg["programs"][name]["domains"].append(domain)
    _save(cfg)
    await update.message.reply_text(
        f"✅ <code>{domain}</code> добавлен!\n"
        f"Добавить ещё или нажми кнопку ниже:",
        parse_mode="HTML", reply_markup=kb_domains(name)
    )
    return ST_PROG


async def del_domain(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    _, name, domain = q.data.split(":", 2)
    cfg = _load()
    if name in cfg["programs"] and domain in cfg["programs"][name]["domains"]:
        cfg["programs"][name]["domains"].remove(domain)
        _save(cfg)
    prog = get_prog(name) or {}
    doms = prog.get("domains", [])
    text = f"<b>🌐 Домены — {name}</b>\n\n"
    text += ("\n".join(f"• {d}" for d in sorted(doms))) if doms else "<i>Нет доменов</i>"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_domains(name))
    return ST_PROG


async def show_headers(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    prog = get_prog(name) or {}
    hdrs = prog.get("headers", {})
    text = f"<b>🔑 Заголовки — {name}</b>\n\n"
    if hdrs:
        for k, v in sorted(hdrs.items()):
            text += f"<code>{k}</code>: {v[:50]}\n"
    else:
        text += (
            "<i>Нет заголовков</i>\n\n"
            "Примеры:\n"
            "<code>Authorization: Bearer TOKEN</code>\n"
            "<code>X-Bug-Bounty: @yourusername</code>\n"
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
        f"<b>➕ Новый заголовок для {name}</b>\n\n"
        f"Введи <b>имя</b> заголовка:\n"
        f"<i>Пример: Authorization</i>",
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
        f"Заголовок: <code>{key}</code>\n\nВведи значение:", parse_mode="HTML"
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
        f"✅ Сохранено:\n<code>{key}: {val[:60]}</code>",
        parse_mode="HTML", reply_markup=kb_headers(name)
    )
    return ST_PROG


async def del_header(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    _, name, key = q.data.split(":", 2)
    cfg = _load()
    cfg["programs"][name]["headers"].pop(key, None)
    _save(cfg)
    prog = get_prog(name) or {}
    hdrs = prog.get("headers", {})
    text = f"<b>🔑 Заголовки — {name}</b>\n\n"
    for k, v in sorted(hdrs.items()):
        text += f"<code>{k}</code>: {v[:50]}\n"
    if not hdrs: text += "<i>Нет заголовков</i>"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_headers(name))
    return ST_PROG


async def show_rate(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["prog"] = name
    prog = get_prog(name) or {}
    rate = prog.get("rate_limit", 30)
    await q.edit_message_text(
        f"<b>⚡ Rate limit — {name}</b>\n\n"
        f"Текущий: <b>{rate}</b> req/s\n\n"
        f"• 10 — осторожно (не забанят)\n"
        f"• 30 — стандарт\n"
        f"• 50 — быстро (риск бана)\n\n"
        f"Введи число (1-100):",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Назад", callback_data=f"P:{name}")]])
    )
    return ST_SET_RATE


async def handle_rate(update: Update, context: ContextTypes.DEFAULT_TYPE):
    name = context.user_data.get("prog")
    try:
        rate = max(1, min(100, int(update.message.text.strip())))
    except:
        await update.message.reply_text("❌ Введи число от 1 до 100")
        return ST_SET_RATE
    cfg = _load()
    if name in cfg["programs"]:
        cfg["programs"][name]["rate_limit"] = rate
        _save(cfg)
    await update.message.reply_text(
        f"✅ Rate limit: <b>{rate}</b> req/s",
        parse_mode="HTML", reply_markup=kb_prog(name)
    )
    return ST_PROG


async def start_scan(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    prog = get_prog(name)
    if not prog or not prog.get("domains"):
        await q.answer("⚠️ Нет доменов! Добавь домены сначала.", show_alert=True)
        return ST_PROG
    doms = prog["domains"]
    chat_id = q.message.chat_id
    await q.edit_message_text(
        f"▶️ <b>Скан запущен — {name}</b>\n\n"
        f"Доменов: {len(doms)}  |  Rate: {prog.get('rate_limit',30)} req/s\n"
        f"Результаты придут в Telegram по завершении.",
        parse_mode="HTML", reply_markup=kb_prog(name)
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
            try: proc.terminate()
            except: pass
    await q.answer(f"⏹ Остановлено: {len(to_stop)}", show_alert=True)
    return ST_PROG


async def scan_all(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    cfg = _load()
    progs = cfg.get("programs", {})
    chat_id = q.message.chat_id
    total = sum(len(p.get("domains",[])) for p in progs.values())
    if total == 0:
        await q.answer("⚠️ Нет доменов!", show_alert=True)
        return ST_MAIN
    await q.edit_message_text(
        f"🔄 <b>Полное сканирование</b>\n"
        f"Программ: {len(progs)}  |  Доменов: {total}",
        parse_mode="HTML", reply_markup=kb_main()
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
        f"🗑 <b>Удалить '{name}'?</b>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[
            InlineKeyboardButton("✅ Да",  callback_data=f"CONFIRMDEL:{name}"),
            InlineKeyboardButton("❌ Нет", callback_data=f"P:{name}"),
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
    cron_d = _load_cron()
    cron_d.pop(name, None)
    _save_cron(cron_d)
    await q.edit_message_text(
        f"✅ <b>{name}</b> удалена",
        parse_mode="HTML", reply_markup=kb_main()
    )
    return ST_MAIN


# ── CRON
async def show_cron_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not HAS_SCHEDULER:
        await q.edit_message_text(
            "<b>🕐 Cron недоступен</b>\n\n"
            "<code>pip install apscheduler --break-system-packages</code>\n"
            "Перезапусти бота.",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Назад", callback_data="BACK")]])
        )
        return ST_MAIN
    cron_d = _load_cron()
    text = "<b>🕐 Cron — автосканирование</b>\n\n"
    if cron_d:
        for name, info in cron_d.items():
            text += f"• <b>{name}</b>: каждые {info.get('interval_hours','?')}ч\n"
    else:
        text += "<i>Нет расписаний</i>\n"
    text += "\nНажми на программу:"
    await q.edit_message_text(text, parse_mode="HTML", reply_markup=kb_cron())
    return ST_MAIN


async def cron_set_prompt(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    context.user_data["cron_prog"] = name
    await q.edit_message_text(
        f"<b>🕐 Cron для {name}</b>\n\nВведи интервал в часах:\n"
        f"<i>Пример: 6, 12, 24</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("◀️ Отмена", callback_data="CRONMENU")]])
    )
    return ST_SET_CRON


async def handle_cron_set(update: Update, context: ContextTypes.DEFAULT_TYPE):
    name = context.user_data.get("cron_prog", "")
    chat_id = update.effective_chat.id
    try:
        hours = max(1, min(168, int(update.message.text.strip())))
    except:
        await update.message.reply_text("❌ Введи число часов (1-168)")
        return ST_SET_CRON
    cron_d = _load_cron()
    cron_d[name] = {"interval_hours": hours, "chat_id": chat_id,
                    "created": datetime.now().isoformat()}
    _save_cron(cron_d)
    if HAS_SCHEDULER and scheduler:
        job_id = f"recon_{name}"
        try: scheduler.remove_job(job_id)
        except: pass
        scheduler.add_job(
            _cron_scan_prog, "interval", hours=hours,
            id=job_id, args=[name, chat_id, context.application],
            coalesce=True, max_instances=1
        )
    await update.message.reply_text(
        f"✅ Cron: <b>{name}</b> каждые <b>{hours}ч</b>",
        parse_mode="HTML", reply_markup=kb_main()
    )
    return ST_MAIN


async def cron_del(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    name = q.data.split(":", 1)[1]
    cron_d = _load_cron()
    cron_d.pop(name, None)
    _save_cron(cron_d)
    if HAS_SCHEDULER and scheduler:
        try: scheduler.remove_job(f"recon_{name}")
        except: pass
    await q.edit_message_text(
        f"✅ Cron для <b>{name}</b> отключён",
        parse_mode="HTML", reply_markup=kb_cron()
    )
    return ST_MAIN


async def _cron_scan_prog(prog_name: str, chat_id: int, app):
    prog = get_prog(prog_name)
    if not prog or not prog.get("domains"): return
    try:
        await app.bot.send_message(chat_id=chat_id,
            text=f"🕐 <b>Cron скан</b>: {prog_name}", parse_mode="HTML")
    except: pass
    for domain in prog["domains"]:
        hf = _make_headers_file(prog_name, prog.get("headers", {}))
        rate = prog.get("rate_limit", 30)
        cmd = ["bash", str(RECON_SCRIPT), "-d", domain,
               "-o", str(RESULTS_DIR), "-t", str(rate)]
        if hf: cmd += ["--headers-file", hf]
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL)
            await proc.wait()
        except Exception as e:
            logger.error(f"Cron scan error {domain}: {e}")


# ── Misc
async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_auth(update.effective_user.id): return
    if not _active_scans:
        await update.message.reply_text("✅ Нет активных сканирований")
        return
    lines = [f"🔄 <b>Активные ({len(_active_scans)}):</b>"]
    for k in sorted(_active_scans):
        prog, domain = k.split(":", 1)
        lines.append(f"  • <b>{prog}</b>: <code>{domain}</code>")
    await update.message.reply_text("\n".join(lines), parse_mode="HTML")


async def cmd_kill(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Принудительно остановить все активные сканы"""
    if not is_auth(update.effective_user.id): return
    count = 0
    for k, proc in list(_active_scans.items()):
        try: proc.terminate(); count += 1
        except: pass
    _active_scans.clear()
    await update.message.reply_text(f"⏹ Остановлено сканов: {count}")


async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "<b>BugBounty Recon Bot v2.1</b>\n\n"
        "/start — главное меню\n"
        "/status — активные сканы\n"
        "/kill — остановить все сканы\n"
        "/help — эта справка\n\n"
        "<b>Если кнопки не работают:</b>\n"
        "<code>pkill -f bot.py && python3 bot.py</code>\n\n"
        "<b>Добавление доменов:</b>\n"
        "1. /start → ➕ Новая программа\n"
        "2. Введи название → автоматически спросит домен\n"
        "3. ▶️ Скан\n",
        parse_mode="HTML"
    )


async def nop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.callback_query: await update.callback_query.answer()


# FIX v2.1: глобальный fallback для потерянных callback
async def global_callback_fallback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Обработчик для callback_query вне активной сессии ConversationHandler.
    Происходит когда бот перезапустился и старые кнопки нажимают снова."""
    q = update.callback_query
    await q.answer("Сессия устарела. Напиши /start", show_alert=False)
    try:
        await q.edit_message_text(
            "⚠️ Сессия устарела после перезапуска бота.\n"
            "Напиши /start чтобы продолжить.",
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton("▶️ Открыть меню", callback_data="RELOAD")
            ]])
        )
    except: pass


async def reload_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Восстановить меню по нажатию на кнопку в устаревшем сообщении."""
    q = update.callback_query
    await q.answer()
    cfg = _load()
    progs = cfg.get("programs", {})
    total_d = sum(len(p.get("domains", [])) for p in progs.values())
    try:
        await q.edit_message_text(
            f"<b>🕷️ BugBounty Recon Bot</b>\n"
            f"Программ: {len(progs)}  |  Доменов: {total_d}\n\n"
            f"Выбери программу:",
            parse_mode="HTML", reply_markup=kb_main()
        )
    except: pass


async def err_handler(update: object, context: ContextTypes.DEFAULT_TYPE):
    logger.error(f"Error: {context.error}", exc_info=context.error)


# =================================================================
# MAIN
# =================================================================
def main():
    global scheduler
    token = BOT_TOKEN or os.getenv("RECON_BOT_TOKEN", "")
    if not token:
        print("ERROR: BOT_TOKEN не задан!")
        print("Заполни BOT_TOKEN в bot.py (~строка 42)")
        print("Или: RECON_BOT_TOKEN=xxxx python3 bot.py")
        sys.exit(1)

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    if HAS_SCHEDULER:
        scheduler = AsyncIOScheduler()
        for prog_name, info in _load_cron().items():
            hours   = info.get("interval_hours", 24)
            chat_id = info.get("chat_id", 0)
            if chat_id:
                # Ссылку на app добавим после build
                scheduler._pending = getattr(scheduler, "_pending", [])
                scheduler._pending.append((prog_name, hours, chat_id))

    app = Application.builder().token(token).build()

    # Восстановить cron задачи с правильной ссылкой на app
    if HAS_SCHEDULER and scheduler:
        for prog_name, hours, chat_id in getattr(scheduler, "_pending", []):
            scheduler.add_job(
                _cron_scan_prog, "interval", hours=hours,
                id=f"recon_{prog_name}",
                args=[prog_name, chat_id, app],
                coalesce=True, max_instances=1
            )
            logger.info(f"Cron restored: {prog_name} every {hours}h")
        scheduler.start()

    conv = ConversationHandler(
        entry_points=[
            CommandHandler("start", cmd_start),
            CommandHandler("menu",  cmd_start),
        ],
        states={
            ST_MAIN: [
                CallbackQueryHandler(show_prog,       pattern=r"^P:"),
                CallbackQueryHandler(start_new_prog,  pattern=r"^NEW$"),
                CallbackQueryHandler(scan_all,        pattern=r"^ALL$"),
                CallbackQueryHandler(show_main,       pattern=r"^BACK$"),
                CallbackQueryHandler(show_cron_menu,  pattern=r"^CRONMENU$"),
                CallbackQueryHandler(cron_set_prompt, pattern=r"^CRONSET:"),
                CallbackQueryHandler(cron_del,        pattern=r"^CRONDEL:"),
                CallbackQueryHandler(reload_menu,     pattern=r"^RELOAD$"),
            ],
            ST_PROG: [
                CallbackQueryHandler(show_main,        pattern=r"^BACK$"),
                CallbackQueryHandler(show_prog,        pattern=r"^P:"),
                CallbackQueryHandler(show_domains,     pattern=r"^DOM:"),
                CallbackQueryHandler(show_headers,     pattern=r"^HDR:"),
                CallbackQueryHandler(show_rate,        pattern=r"^RATE:"),
                CallbackQueryHandler(start_add_domain, pattern=r"^ADDD:"),
                CallbackQueryHandler(del_domain,       pattern=r"^DELD:"),
                CallbackQueryHandler(start_add_header, pattern=r"^ADDH:"),
                CallbackQueryHandler(del_header,       pattern=r"^DELH:"),
                CallbackQueryHandler(start_scan,       pattern=r"^SCAN:"),
                CallbackQueryHandler(stop_scan,        pattern=r"^STOP:"),
                CallbackQueryHandler(del_prog,         pattern=r"^DELPROG:"),
                CallbackQueryHandler(confirm_del_prog, pattern=r"^CONFIRMDEL:"),
                CallbackQueryHandler(nop,              pattern=r"^NOP$"),
            ],
            ST_ADD_PROG:   [
                MessageHandler(filters.TEXT & ~filters.COMMAND, handle_new_prog),
                CallbackQueryHandler(show_main, pattern=r"^BACK$"),
            ],
            ST_ADD_DOMAIN: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, handle_add_domain),
                CallbackQueryHandler(show_domains, pattern=r"^DOM:"),
                CallbackQueryHandler(show_prog,    pattern=r"^P:"),
            ],
            ST_ADD_HDR_KEY: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, handle_hdr_key),
                CallbackQueryHandler(show_headers, pattern=r"^HDR:"),
            ],
            ST_ADD_HDR_VAL: [MessageHandler(filters.TEXT & ~filters.COMMAND, handle_hdr_val)],
            ST_SET_RATE:    [
                MessageHandler(filters.TEXT & ~filters.COMMAND, handle_rate),
                CallbackQueryHandler(show_prog, pattern=r"^P:"),
            ],
            ST_SET_CRON:    [
                MessageHandler(filters.TEXT & ~filters.COMMAND, handle_cron_set),
                CallbackQueryHandler(show_cron_menu, pattern=r"^CRONMENU$"),
            ],
        },
        fallbacks=[
            CommandHandler("start",  cmd_start),
            CommandHandler("status", cmd_status),
            CommandHandler("kill",   cmd_kill),
            CommandHandler("help",   cmd_help),
        ],
    )

    app.add_handler(conv)
    # FIX v2.1: глобальный обработчик для устаревших кнопок (RELOAD и всё остальное)
    app.add_handler(CallbackQueryHandler(reload_menu,             pattern=r"^RELOAD$"))
    app.add_handler(CallbackQueryHandler(global_callback_fallback))  # ловит ВСЁ остальное
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("kill",   cmd_kill))
    app.add_handler(CommandHandler("help",   cmd_help))
    app.add_error_handler(err_handler)

    print(f"BugBounty Recon Bot v2.1 запущен")
    print(f"Config:    {PROGRAMS_FILE}")
    print(f"Script:    {RECON_SCRIPT}")
    print(f"Scheduler: {'OK' if HAS_SCHEDULER else 'нет'}")
    print(f"Auth:      {'ALL (dev)' if not AUTHORIZED_USERS else AUTHORIZED_USERS}")
    print(f"")
    print(f"Если кнопки не работают — убей старый процесс:")
    print(f"  pkill -f bot.py && python3 bot.py")

    # FIX v2.1: drop_pending_updates=True — игнорировать апдейты накопившиеся пока бот не работал
    app.run_polling(
        allowed_updates=Update.ALL_TYPES,
        drop_pending_updates=True  # <- ключевой фикс!
    )


if __name__ == "__main__":
    main()
