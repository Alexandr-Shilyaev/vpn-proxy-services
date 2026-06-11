#!/usr/bin/env python3
"""
Единый Telegram-бот для управления self-hosted VPN/прокси-сервисами.

Один бот -> несколько протоколов (backend'ов). Сейчас активен только AmneziaWG;
VLESS+Reality и Hysteria2 добавляются в реестр PROTOCOLS по мере реализации.

Контракт backend'а (скрипты в каталоге протокола, см. REPO_DIR/<proto>/):
  add_user.sh  <имя>  -> печатает строку  CONF=<путь> QR=<путь>
  del_user.sh  <имя>  -> печатает строку  DELETED=<имя>
  list_users.sh       -> таблица (первый столбец — имя) или "Клиентов пока нет."
  + клиенты хранятся в каталоге state_clients_dir (по одному подкаталогу на клиента)

Конфигурация — через переменные окружения (см. config.env.example):
  BOT_TOKEN    — токен от @BotFather
  ADMIN_IDS    — id админов через запятую
  REPO_DIR     — корень проекта на сервере (по умолчанию /opt/vpn-proxy-services)
"""

import asyncio
import html
import os
import re
from dataclasses import dataclass
from pathlib import Path

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    ConversationHandler,
    MessageHandler,
    filters,
)

# ---------- Конфигурация ----------
BOT_TOKEN = os.environ.get("BOT_TOKEN", "").strip()
REPO_DIR = Path(os.environ.get("REPO_DIR", "/opt/vpn-proxy-services"))
ADMIN_IDS = {
    int(x) for x in re.split(r"[,\s]+", os.environ.get("ADMIN_IDS", "")) if x.strip().isdigit()
}

NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
ASK_NAME = 1


# ---------- Реестр протоколов ----------
@dataclass(frozen=True)
class Protocol:
    key: str                 # короткий идентификатор (в callback_data)
    label: str               # отображаемое имя
    dirname: str             # подкаталог в REPO_DIR
    clients_dir: str         # где backend хранит клиентов

    @property
    def path(self) -> Path:
        return REPO_DIR / self.dirname


# Активные протоколы. Новый протокол = ещё одна запись здесь
# (после того как в REPO_DIR/<dirname>/ появятся add_user.sh/del_user.sh/list_users.sh).
PROTOCOLS: dict[str, Protocol] = {
    "amneziawg": Protocol(
        key="amneziawg",
        label="AmneziaWG",
        dirname="amneziawg",
        clients_dir="/etc/awg-vpn/clients",
    ),
}


def get_proto(key: str) -> Protocol | None:
    return PROTOCOLS.get(key)


# ---------- Доступ ----------
def is_admin(update: Update) -> bool:
    user = update.effective_user
    return bool(user and user.id in ADMIN_IDS)


async def deny(update: Update) -> None:
    if update.callback_query:
        await update.callback_query.answer("Нет доступа.", show_alert=True)
    elif update.effective_message:
        await update.effective_message.reply_text("У вас нет доступа к этому боту.")


# ---------- Запуск backend-скриптов ----------
async def run_script(proto: Protocol, script: str, *args: str) -> tuple[int, str]:
    path = proto.path / script
    proc = await asyncio.create_subprocess_exec(
        "bash", str(path), *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    return proc.returncode, out.decode(errors="replace")


def parse_kv(output: str, key: str) -> str | None:
    m = re.search(rf"{key}=(\S+)", output)
    return m.group(1) if m else None


def list_client_names(proto: Protocol) -> list[str]:
    base = Path(proto.clients_dir)
    if not base.is_dir():
        return []
    return sorted(p.name for p in base.iterdir() if p.is_dir())


# ---------- Меню ----------
def main_menu() -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(p.label, callback_data=f"proto:{p.key}")]
        for p in PROTOCOLS.values()
    ]
    return InlineKeyboardMarkup(rows)


def proto_menu(proto: Protocol) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        [
            [InlineKeyboardButton("Добавить пользователя", callback_data=f"add:{proto.key}")],
            [InlineKeyboardButton("Удалить пользователя", callback_data=f"delmenu:{proto.key}")],
            [InlineKeyboardButton("Список пользователей", callback_data=f"list:{proto.key}")],
            [InlineKeyboardButton("« Протоколы", callback_data="menu")],
        ]
    )


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return await deny(update)
    await update.effective_message.reply_text(
        "<b>VPN/Proxy — управление</b>\nВыберите протокол:",
        reply_markup=main_menu(),
        parse_mode="HTML",
    )


async def on_menu(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return await deny(update)
    q = update.callback_query
    await q.answer()
    await q.edit_message_text(
        "<b>VPN/Proxy — управление</b>\nВыберите протокол:",
        reply_markup=main_menu(),
        parse_mode="HTML",
    )


async def on_proto(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return await deny(update)
    q = update.callback_query
    await q.answer()
    proto = get_proto(q.data.split(":", 1)[1])
    if not proto:
        return await q.edit_message_text("Неизвестный протокол.", reply_markup=main_menu())
    await q.edit_message_text(
        f"<b>{html.escape(proto.label)}</b>\nВыберите действие:",
        reply_markup=proto_menu(proto),
        parse_mode="HTML",
    )


# ---------- Список ----------
async def on_list(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return await deny(update)
    q = update.callback_query
    await q.answer()
    proto = get_proto(q.data.split(":", 1)[1])
    if not proto:
        return await q.edit_message_text("Неизвестный протокол.", reply_markup=main_menu())
    code, out = await run_script(proto, "list_users.sh")
    text = out.strip() or "Клиентов пока нет."
    await q.edit_message_text(
        f"<b>{html.escape(proto.label)} — пользователи:</b>\n<pre>{html.escape(text)}</pre>",
        reply_markup=InlineKeyboardMarkup(
            [[InlineKeyboardButton("« Назад", callback_data=f"proto:{proto.key}")]]
        ),
        parse_mode="HTML",
    )


# ---------- Удаление ----------
async def on_del_menu(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return await deny(update)
    q = update.callback_query
    await q.answer()
    proto = get_proto(q.data.split(":", 1)[1])
    if not proto:
        return await q.edit_message_text("Неизвестный протокол.", reply_markup=main_menu())
    names = list_client_names(proto)
    back = [[InlineKeyboardButton("« Назад", callback_data=f"proto:{proto.key}")]]
    if not names:
        return await q.edit_message_text("Клиентов пока нет.", reply_markup=InlineKeyboardMarkup(back))
    rows = [[InlineKeyboardButton(n, callback_data=f"del:{proto.key}:{n}")] for n in names]
    rows += back
    await q.edit_message_text(f"{proto.label}: кого удалить?", reply_markup=InlineKeyboardMarkup(rows))


async def on_del(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return await deny(update)
    q = update.callback_query
    await q.answer()
    _, key, name = q.data.split(":", 2)
    proto = get_proto(key)
    if not proto or not NAME_RE.match(name):
        return await q.edit_message_text("Некорректный запрос.", reply_markup=main_menu())
    code, out = await run_script(proto, "del_user.sh", name)
    back = [[InlineKeyboardButton("« Назад", callback_data=f"proto:{proto.key}")]]
    if code != 0:
        return await q.edit_message_text(
            f"Ошибка:\n<pre>{html.escape(out[-3000:])}</pre>",
            reply_markup=InlineKeyboardMarkup(back), parse_mode="HTML",
        )
    await q.edit_message_text(
        f"Пользователь <b>{html.escape(name)}</b> удалён ({proto.label}).",
        reply_markup=InlineKeyboardMarkup(back), parse_mode="HTML",
    )


# ---------- Добавление (диалог) ----------
async def on_add(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    if not is_admin(update):
        await deny(update)
        return ConversationHandler.END
    q = update.callback_query
    await q.answer()
    proto = get_proto(q.data.split(":", 1)[1])
    if not proto:
        await q.edit_message_text("Неизвестный протокол.", reply_markup=main_menu())
        return ConversationHandler.END
    context.user_data["proto"] = proto.key
    await q.edit_message_text(
        f"{proto.label}: введите имя нового пользователя "
        "(латиница, цифры, _ или -).\nДля отмены: /cancel"
    )
    return ASK_NAME


async def on_name(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    if not is_admin(update):
        await deny(update)
        return ConversationHandler.END
    proto = get_proto(context.user_data.get("proto", ""))
    if not proto:
        await update.message.reply_text("Сессия сброшена, начните заново: /start")
        return ConversationHandler.END

    name = (update.message.text or "").strip()
    if not NAME_RE.match(name):
        await update.message.reply_text(
            "Недопустимое имя. Разрешено: A-Z a-z 0-9 _ - (до 32 символов). "
            "Попробуйте ещё раз или /cancel."
        )
        return ASK_NAME

    msg = await update.message.reply_text(
        f"Создаю пользователя <b>{html.escape(name)}</b> ({proto.label})…", parse_mode="HTML"
    )
    code, out = await run_script(proto, "add_user.sh", name)
    if code != 0:
        await msg.edit_text(f"Ошибка:\n<pre>{html.escape(out[-3000:])}</pre>", parse_mode="HTML")
        return ConversationHandler.END

    conf = parse_kv(out, "CONF")
    qr = parse_kv(out, "QR")
    await msg.edit_text(f"Пользователь <b>{html.escape(name)}</b> создан.", parse_mode="HTML")

    chat_id = update.effective_chat.id
    if qr and Path(qr).is_file():
        with open(qr, "rb") as f:
            await context.bot.send_photo(chat_id, f, caption=f"{proto.label}: QR для {name}")
    if conf and Path(conf).is_file():
        with open(conf, "rb") as f:
            await context.bot.send_document(chat_id, f, filename=f"{name}.conf")

    await context.bot.send_message(
        chat_id, "Готово.",
        reply_markup=InlineKeyboardMarkup(
            [[InlineKeyboardButton("« Назад", callback_data=f"proto:{proto.key}")]]
        ),
    )
    return ConversationHandler.END


async def on_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    await update.message.reply_text("Отменено.", reply_markup=main_menu())
    return ConversationHandler.END


# ---------- main ----------
def main() -> None:
    if not BOT_TOKEN:
        raise SystemExit("BOT_TOKEN не задан (см. bot.env).")
    if not ADMIN_IDS:
        raise SystemExit("ADMIN_IDS не задан — некому управлять ботом.")

    app = Application.builder().token(BOT_TOKEN).build()

    conv = ConversationHandler(
        entry_points=[CallbackQueryHandler(on_add, pattern=r"^add:")],
        states={ASK_NAME: [MessageHandler(filters.TEXT & ~filters.COMMAND, on_name)]},
        fallbacks=[CommandHandler("cancel", on_cancel)],
        per_message=False,
    )

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(conv)
    app.add_handler(CallbackQueryHandler(on_menu, pattern=r"^menu$"))
    app.add_handler(CallbackQueryHandler(on_proto, pattern=r"^proto:"))
    app.add_handler(CallbackQueryHandler(on_list, pattern=r"^list:"))
    app.add_handler(CallbackQueryHandler(on_del_menu, pattern=r"^delmenu:"))
    app.add_handler(CallbackQueryHandler(on_del, pattern=r"^del:"))

    print("VPN/Proxy bot started.")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
