"""
Python обертка для Swift для работы с pymax.
Обеспечивает синхронный интерфейс для асинхронного pymax клиента.
"""

import asyncio
import concurrent.futures
import datetime
import json
import os
import ssl
import sys
import time
import uuid
import threading
from typing import Any, Dict, List, Optional

# Добавляем текущую директорию в sys.path для поиска модулей
_current_dir = os.path.dirname(os.path.abspath(__file__))
if _current_dir not in sys.path:
    sys.path.insert(0, _current_dir)

PYMAX_AVAILABLE = False
_DEBUG = os.environ.get("WHITEMAX_DEBUG") == "1"
_PYMAX_IMPORT_ERROR: Optional[str] = None


def _dprint(*args: Any, **kwargs: Any) -> None:
    if _DEBUG:
        print(*args, **kwargs)


def _set_import_error(prefix: str, err: Exception) -> None:
    global _PYMAX_IMPORT_ERROR
    if _PYMAX_IMPORT_ERROR is None:
        _PYMAX_IMPORT_ERROR = f"{prefix}: {type(err).__name__}: {err}"
try:
    # pydantic-core is required by pydantic v2 (pymax dependencies).
    # On-device failures are often OSError/dlopen (not just ImportError).
    import pydantic_core  # noqa: F401

    # Пытаемся импортировать pymax
    # Для iOS используем SocketMaxClient вместо MaxClient
    from pymax import SocketMaxClient
    from pymax.files import File, Photo
    from pymax.payloads import UserAgentPayload
    from pymax.types import Chat, Message
    from pymax.exceptions import SocketNotConnectedError, SocketSendError
    PYMAX_AVAILABLE = True
    _dprint("✓ pymax imported successfully")
except Exception as e:
    # Если импорт не удался, создаем заглушки для типов
    import sys
    import os
    import traceback
    
    _set_import_error("Failed to import pymax/pydantic_core", e)
    _dprint(f"Warning: Failed to import pymax: {e}")
    _dprint(f"Error type: {type(e).__name__}")
    _dprint(f"Python path: {sys.path}")
    
    # Проверяем наличие pymax
    app_dir = os.path.dirname(os.path.abspath(__file__))
    pymax_dir = os.path.join(app_dir, "pymax")
    _dprint(f"Looking for pymax at: {pymax_dir}")
    _dprint(f"pymax exists: {os.path.exists(pymax_dir)}")
    
    # Проверяем наличие __init__.py
    pymax_init = os.path.join(pymax_dir, "__init__.py")
    if os.path.exists(pymax_init):
        _dprint("✓ pymax/__init__.py exists")
    else:
        _dprint("✗ pymax/__init__.py NOT found")
    
    # Выводим полный traceback для диагностики
    if _DEBUG:
        print("Full traceback:")
        traceback.print_exc()
    
    # Устанавливаем заглушки
    SocketMaxClient = None
    UserAgentPayload = None
    Chat = None
    Message = None
    Photo = None
    File = None


class MaxClientWrapper:
    """Синхронная обертка для SocketMaxClient (для iOS)."""

    @staticmethod
    def _get_field(obj: Any, *names: str, default: Any = None) -> Any:
        """Безопасно получить поле у dict / объекта / Pydantic модели (на случай смены типов в pymax)."""
        if obj is None:
            return default
        if isinstance(obj, dict):
            for name in names:
                if name in obj:
                    return obj.get(name)
            return default
        for name in names:
            if hasattr(obj, name):
                return getattr(obj, name)
        return default

    @staticmethod
    def _normalize_time_to_int_ms(value: Any) -> Optional[int]:
        """Привести время сообщения к Int (ms), чтобы JSON всегда был сериализуем и совместим со Swift."""
        if value is None:
            return None
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, (int, float)):
            return int(value)
        if isinstance(value, datetime.datetime):
            # Для совместимости со Swift моделью используем миллисекунды
            return int(value.timestamp() * 1000)
        if isinstance(value, str):
            s = value.strip()
            if s.isdigit():
                try:
                    return int(s)
                except Exception:
                    return None
        return None

    def _message_to_dict(self, msg: Any, fallback_chat_id: Optional[int] = None) -> Optional[Dict[str, Any]]:
        """Конвертировать Message (или dict-подобный объект) в JSON-совместимый dict для Swift."""
        if msg is None:
            return None

        try:
            msg_id = self._get_field(msg, "id", default=None)
            if msg_id is None:
                return None

            chat_id = self._get_field(msg, "chat_id", "chatId", default=None)
            if chat_id is None:
                chat_id = fallback_chat_id
            if chat_id is None:
                return None

            text = self._get_field(msg, "text", default="") or ""
            sender_id = self._get_field(msg, "sender", "sender_id", "senderId", default=None)

            time_val = self._get_field(msg, "time", default=None)
            date_val = self._get_field(msg, "date", default=None)
            time_ms = self._normalize_time_to_int_ms(time_val) or self._normalize_time_to_int_ms(date_val)

            msg_type = self._get_field(msg, "type", default=None)
            if msg_type is not None:
                # Enum/value/object tolerant
                if hasattr(msg_type, "value"):
                    msg_type = msg_type.value
                else:
                    msg_type = str(msg_type)

            # reply link
            reply_to = None
            link = self._get_field(msg, "link", default=None)
            if link is not None:
                link_type = self._get_field(link, "type", default=None)
                if hasattr(link_type, "value"):
                    link_type = link_type.value
                if str(link_type).upper() == "REPLY":
                    reply_to = self._get_field(link, "message_id", "messageId", default=None)
                    if reply_to is not None:
                        reply_to = str(reply_to)

            # reactions counters
            reactions: Dict[str, int] = {}
            reaction_info = self._get_field(msg, "reactionInfo", "reaction_info", default=None)
            counters = self._get_field(reaction_info, "counters", default=None) if reaction_info is not None else None
            if isinstance(counters, list):
                for c in counters:
                    r = self._get_field(c, "reaction", default=None)
                    cnt = self._get_field(c, "count", default=0)
                    if r is not None:
                        try:
                            reactions[str(r)] = int(cnt or 0)
                        except Exception:
                            reactions[str(r)] = 0

            # attachments
            attachments: List[Dict[str, Any]] = []
            attaches = self._get_field(msg, "attaches", default=None)
            if isinstance(attaches, list):
                for a in attaches:
                    a_type = self._get_field(a, "type", default=None)
                    if hasattr(a_type, "value"):
                        a_type = a_type.value
                    a_type_str = str(a_type) if a_type is not None else "UNKNOWN"
                    if a_type_str.upper() == "PHOTO":
                        photo_id = self._get_field(a, "photo_id", "photoId", default=None)
                        base_url = self._get_field(a, "base_url", "baseUrl", default=None)
                        # Cache-buster: AsyncImage caches by URL; some base URLs can be template-like.
                        if base_url:
                            try:
                                sep = "&" if "?" in str(base_url) else "?"
                                pid = int(photo_id) if photo_id is not None else 0
                                base_url = f"{base_url}{sep}pid={pid}&mid={str(msg_id)}"
                            except Exception:
                                pass
                        attachments.append(
                            {
                                "id": int(photo_id) if photo_id is not None else 0,
                                "type": "PHOTO",
                                "url": base_url,
                                "thumbnail_url": base_url,
                                "file_name": None,
                                "file_size": None,
                            }
                        )
                    elif a_type_str.upper() == "FILE":
                        file_id = self._get_field(a, "file_id", "fileId", default=None)
                        name = self._get_field(a, "name", default=None)
                        size = self._get_field(a, "size", default=None)
                        attachments.append(
                            {
                                "id": int(file_id) if file_id is not None else 0,
                                "type": "FILE",
                                "url": None,
                                "thumbnail_url": None,
                                "file_name": name,
                                "file_size": int(size) if size is not None else None,
                            }
                        )
                    elif a_type_str.upper() == "VIDEO":
                        video_id = self._get_field(a, "video_id", "videoId", default=None)
                        thumb = self._get_field(a, "thumbnail", default=None)
                        attachments.append(
                            {
                                "id": int(video_id) if video_id is not None else 0,
                                "type": "VIDEO",
                                "url": None,
                                "thumbnail_url": thumb,
                                "file_name": None,
                                "file_size": None,
                            }
                        )

            return {
                "id": str(msg_id),
                "chat_id": int(chat_id),
                "text": text,
                "sender_id": sender_id,
                "date": time_ms,
                "time": time_ms,
                "type": msg_type,
                "reply_to": reply_to,
                "reactions": reactions if reactions else None,
                "attachments": attachments if attachments else None,
            }
        except Exception:
            return None

    @staticmethod
    def _coerce_int(value: Any) -> Optional[int]:
        if value is None:
            return None
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            return int(value)
        if isinstance(value, str):
            s = value.strip()
            if s.isdigit():
                try:
                    return int(s)
                except Exception:
                    return None
        return None

    @classmethod
    def _coerce_int_list(cls, value: Any) -> List[int]:
        if value is None:
            return []
        if isinstance(value, (list, tuple)):
            out: List[int] = []
            for v in value:
                iv = cls._coerce_int(v)
                if iv is not None:
                    out.append(iv)
            return out
        one = cls._coerce_int(value)
        return [one] if one is not None else []

    async def _ensure_connected_and_session(self) -> None:
        """Убедиться, что socket подключен и сессия (token/me) инициализирована."""
        if self.client is None:
            raise RuntimeError("Client not initialized")

        if self._conn_lock is None:
            self._conn_lock = asyncio.Lock()

        async with self._conn_lock:
            if not getattr(self.client, "is_connected", False):
                # Best-effort cleanup: cancel recv/outgoing tasks before reconnecting.
                # This avoids accumulating pending tasks and improves reconnect stability.
                try:
                    if hasattr(self.client, "_cleanup_client"):
                        await self.client._cleanup_client()
                except Exception:
                    # fallback: close socket only
                    if hasattr(self.client, "_socket") and getattr(self.client, "_socket", None):
                        try:
                            self.client._socket.close()
                        except Exception:
                            pass
                    self.client.is_connected = False

                await self.client.connect(self.client.user_agent)

                if getattr(self.client, "_token", None):
                    await self.client._sync(self.client.user_agent)
                    await self.client._post_login_tasks(sync=False)

            elif getattr(self.client, "_token", None) and not getattr(self.client, "me", None):
                await self.client._sync(self.client.user_agent)
                await self.client._post_login_tasks(sync=False)

    def _reaction_info_to_dict(self, reaction_info: Any) -> Optional[Dict[str, Any]]:
        """Конвертировать ReactionInfo в JSON-совместимый dict для Swift."""
        if reaction_info is None:
            return None
        try:
            counters_raw = self._get_field(reaction_info, "counters", default=None) or []
            counters: List[Dict[str, Any]] = []
            for c in counters_raw or []:
                counters.append(
                    {
                        "reaction": self._get_field(c, "reaction", default=None),
                        "count": self._get_field(c, "count", default=0),
                    }
                )
            return {
                "total_count": self._get_field(
                    reaction_info, "total_count", "totalCount", default=0
                ),
                "your_reaction": self._get_field(
                    reaction_info, "your_reaction", "yourReaction", default=None
                ),
                "counters": counters,
            }
        except Exception:
            return None

    def _emit_event(self, event: Dict[str, Any]) -> None:
        """Best-effort: сохранить событие в events dir (атомарно), чтобы Swift мог его подхватить."""
        try:
            os.makedirs(self._events_dir, exist_ok=True)
            ts_ms = int(time.time() * 1000)
            event.setdefault("ts_ms", ts_ms)
            filename = f"{ts_ms}_{uuid.uuid4().hex}.json"
            tmp_path = os.path.join(self._events_dir, f".{filename}.tmp")
            final_path = os.path.join(self._events_dir, filename)
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(event, f, ensure_ascii=False)
            os.replace(tmp_path, final_path)
        except Exception:
            # Никогда не падаем из-за событий — это обновления UI.
            pass

    def get_events_dir(self) -> Dict[str, Any]:
        return {"success": True, "events_dir": self._events_dir}

    def register_event_callbacks(self, events_dir: Optional[str] = None) -> Dict[str, Any]:
        """
        Регистрирует pymax callbacks (message/edit/delete/reaction/chat_update) и пишет события в JSON-файлы.
        Swift затем мониторит папку через DispatchSource.
        """
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}

        if events_dir:
            self._events_dir = events_dir
        os.makedirs(self._events_dir, exist_ok=True)

        if self._callbacks_registered:
            return {"success": True, "events_dir": self._events_dir, "already_registered": True}

        try:
            async def _on_message(msg: Any) -> None:
                msg_dict = self._message_to_dict(msg)
                if msg_dict:
                    self._emit_event({"type": "message_new", "message": msg_dict})

            async def _on_message_edit(msg: Any) -> None:
                msg_dict = self._message_to_dict(msg)
                if msg_dict:
                    self._emit_event({"type": "message_edit", "message": msg_dict})

            async def _on_message_delete(msg: Any) -> None:
                msg_dict = self._message_to_dict(msg)
                if msg_dict:
                    self._emit_event({"type": "message_delete", "message": msg_dict})

            self.client.on_message()(_on_message)
            self.client.on_message_edit()(_on_message_edit)
            self.client.on_message_delete()(_on_message_delete)

            async def _on_reaction_change(message_id: str, chat_id: int, reaction_info: Any) -> None:
                self._emit_event(
                    {
                        "type": "reaction_change",
                        "chat_id": int(chat_id),
                        "message_id": str(message_id),
                        "reaction_info": self._reaction_info_to_dict(reaction_info),
                    }
                )

            async def _on_chat_update(chat: Any) -> None:
                chat_dict = {
                    "id": self._get_field(chat, "id", default=None),
                    "title": self._get_field(chat, "title", default="") or "",
                    "type": self._get_field(chat, "type", default=None),
                    "icon_url": self._get_field(chat, "base_icon_url", "baseIconUrl", default=None),
                }
                self._emit_event({"type": "chat_update", "chat": chat_dict})

            self.client.on_reaction_change(_on_reaction_change)
            self.client.on_chat_update(_on_chat_update)

            self._callbacks_registered = True
            # Ensure background keepalive so events arrive even when Swift is idle.
            try:
                self._run_async(self._ensure_keepalive_started())
            except Exception:
                pass
            return {"success": True, "events_dir": self._events_dir}
        except Exception as e:
            return {"success": False, "error": str(e)}
    
    def __init__(self, phone: str, work_dir: Optional[str] = None, token: Optional[str] = None):
        """
        Инициализация обертки.
        
        :param phone: Номер телефона
        :param work_dir: Рабочая директория для сохранения сессии
        :param token: Токен авторизации (если есть сохраненная сессия)
        """
        if SocketMaxClient is None:
            raise RuntimeError("pymax not available")
        
        # Определяем рабочую директорию
        if work_dir is None:
            # Используем временную директорию для iOS
            work_dir = os.path.join(os.path.expanduser("~"), "Documents", "max_cache")
            os.makedirs(work_dir, exist_ok=True)
        
        self.phone = phone
        self.work_dir = work_dir
        self.token = token
        self.client: Optional[SocketMaxClient] = None
        # IMPORTANT (stability):
        # pymax (SocketMaxClient) starts long-lived asyncio Tasks for socket recv/outgoing loops.
        # If we execute coroutines via loop.run_until_complete(), the event loop stops afterwards and
        # those tasks get destroyed => frequent disconnect/reconnect storms + "Task was destroyed" warnings.
        #
        # We keep a dedicated asyncio loop running forever in a Python background thread and schedule
        # coroutines onto it via asyncio.run_coroutine_threadsafe(). Swift/PythonKit still calls into
        # Python only from ONE Swift thread (enforced by PythonBridge.withPython).
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._loop_thread: Optional[threading.Thread] = None
        self._loop_ready = threading.Event()
        self._loop_lock = threading.Lock()
        self._loop_thread_ident: Optional[int] = None
        self._events_dir: str = os.path.join(self.work_dir, "events")
        self._callbacks_registered: bool = False
        self._conn_lock: Optional[asyncio.Lock] = None
        self._keepalive_task: Optional[asyncio.Task] = None
        self._keepalive_stop: Optional[asyncio.Event] = None

    async def _keepalive_loop(self) -> None:
        """
        Background loop that keeps the socket/session alive for real-time events.
        Runs on our dedicated asyncio loop thread.
        """
        if self.client is None:
            return
        if self._keepalive_stop is None:
            self._keepalive_stop = asyncio.Event()

        # Small initial delay to let login/start flows settle.
        await asyncio.sleep(0.2)
        while not self._keepalive_stop.is_set():
            try:
                # Only keepalive if we have auth token; otherwise no realtime.
                if getattr(self.client, "_token", None):
                    # Ensure connected + session (sync/post_login tasks) so server delivers push events.
                    await self._ensure_connected_and_session()
                await asyncio.sleep(1.0)
            except asyncio.CancelledError:
                break
            except Exception:
                # Never crash keepalive; back off a bit.
                try:
                    await asyncio.sleep(1.5)
                except Exception:
                    pass

    async def _ensure_keepalive_started(self) -> None:
        """Start keepalive task once (best-effort)."""
        if self.client is None:
            return
        if self._keepalive_stop is None:
            self._keepalive_stop = asyncio.Event()
        if self._keepalive_task is not None and not self._keepalive_task.done():
            return
        # Reset stop flag if previously stopped
        try:
            self._keepalive_stop.clear()
        except Exception:
            self._keepalive_stop = asyncio.Event()
        self._keepalive_task = asyncio.create_task(self._keepalive_loop(), name="whitemax-keepalive")

    def _ensure_loop_thread(self) -> asyncio.AbstractEventLoop:
        """Ensure a dedicated asyncio loop thread is running; return the loop."""
        with self._loop_lock:
            if (
                self._loop_thread is not None
                and self._loop is not None
                and not self._loop.is_closed()
                and self._loop.is_running()
            ):
                return self._loop

            # Reset state
            self._loop_ready.clear()
            self._loop = None
            self._loop_thread_ident = None

            def _worker() -> None:
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                self._loop = loop
                self._loop_thread_ident = threading.get_ident()
                self._loop_ready.set()
                try:
                    loop.run_forever()
                finally:
                    # Best-effort: cancel pending tasks to avoid "Task was destroyed but it is pending!"
                    try:
                        pending = asyncio.all_tasks(loop)
                        for t in pending:
                            t.cancel()
                        if pending:
                            loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
                    except Exception:
                        pass
                    try:
                        loop.close()
                    except Exception:
                        pass

            t = threading.Thread(target=_worker, name="whitemax-asyncio-loop", daemon=True)
            self._loop_thread = t
            t.start()

        # Wait outside lock
        self._loop_ready.wait(timeout=2.0)
        if self._loop is None:
            raise RuntimeError("Failed to start asyncio loop thread")
        return self._loop

    def _stop_loop_thread(self) -> None:
        """Stop dedicated asyncio loop thread (best-effort)."""
        with self._loop_lock:
            loop = self._loop
            t = self._loop_thread

        if loop is not None and not loop.is_closed():
            try:
                loop.call_soon_threadsafe(loop.stop)
            except Exception:
                pass

        if t is not None and t.is_alive():
            try:
                t.join(timeout=1.5)
            except Exception:
                pass

        with self._loop_lock:
            self._loop_thread = None
            self._loop_thread_ident = None
            self._loop = None
            self._loop_ready.clear()
        
    def _get_loop(self) -> asyncio.AbstractEventLoop:
        """Получить или создать event loop."""
        return self._ensure_loop_thread()
    
    def _run_async(self, coro):
        """Run an async coroutine synchronously without stopping the asyncio loop."""
        loop = self._ensure_loop_thread()
        try:
            # If called from loop thread, this sync API would deadlock.
            if self._loop_thread_ident is not None and threading.get_ident() == self._loop_thread_ident:
                raise RuntimeError("_run_async called from asyncio loop thread")

            fut = asyncio.run_coroutine_threadsafe(coro, loop)
            return fut.result(timeout=60)
        except concurrent.futures.TimeoutError as e:
            _dprint("Error in _run_async: timeout")
            raise TimeoutError("Python async call timed out") from e
        except Exception as e:
            _dprint(f"Error in _run_async: {e}")
            if _DEBUG:
                import traceback
                traceback.print_exc()
            raise
    
    def create_client(self) -> Dict[str, Any]:
        """
        Создать клиент SocketMaxClient для iOS.
        
        :return: Dict с результатом инициализации
        """
        try:
            # Для iOS используем SocketMaxClient с device_type="IOS"
            # SocketMaxClient использует TCP Socket вместо WebSocket
            ua = UserAgentPayload(device_type="IOS", app_version="25.12.14")
            self.client = SocketMaxClient(
                phone=self.phone,
                work_dir=self.work_dir,
                headers=ua,
                token=self.token,  # Передаем токен если есть
                reconnect=False,
            )
            return {"success": True, "message": "Client created"}
        except Exception as e:
            return {"success": False, "error": str(e)}
    
    def request_code(self, phone: Optional[str] = None, language: str = "ru") -> Dict[str, Any]:
        """
        Запросить код авторизации.
        
        :param phone: Номер телефона (если не указан, используется из __init__)
        :param language: Язык для сообщения
        :return: Dict с temp_token или ошибкой
        """
        if self.client is None:
            result = self.create_client()
            if not result.get("success"):
                return result
        
        phone = phone or self.phone
        
        try:
            async def _request():
                # Сначала создаем клиент, если его нет
                if self.client is None:
                    result = self.create_client()
                    if not result.get("success"):
                        return result
                
                # Подключаемся к Socket, если еще не подключены или соединение потеряно
                if not self.client.is_connected:
                    try:
                        await self.client.connect(self.client.user_agent)
                    except Exception as conn_error:
                        # Если соединение не удалось, пробуем еще раз
                        await asyncio.sleep(0.5)  # Небольшая задержка перед повтором
                        await self.client.connect(self.client.user_agent)
                
                # Запрашиваем код авторизации
                temp_token = await self.client.request_code(phone, language)
                return {"success": True, "temp_token": temp_token}
            
            return self._run_async(_request())
        except Exception as e:
            return {"success": False, "error": str(e)}
    
    def login_with_code(self, temp_token: str, code: str) -> Dict[str, Any]:
        """
        Авторизоваться с кодом.
        
        :param temp_token: Временный токен из request_code
        :param code: 6-значный код верификации
        :return: Dict с результатом авторизации
        """
        if self.client is None:
            result = self.create_client()
            if not result.get("success"):
                return result
        
        try:
            async def _login():
                def _is_code_invalid_error(err: Exception) -> bool:
                    s = str(err).lower()
                    # Серверные ошибки: "код устарел" / лимит попыток
                    return (
                        "этот код устарел" in s
                        or "получите новый" in s
                        or "attempt.limit" in s
                        or "error.code.attempt.limit" in s
                    )

                def _is_send_and_wait_error(err: Exception) -> bool:
                    # Кейс, когда запрос мог уйти на сервер, но ответ не дождались.
                    # Повторять тот же код опасно: можно получить "код устарел"/лимит попыток.
                    t = type(err).__name__
                    s = str(err).lower()
                    return (
                        "socketsenderror" in t.lower()
                        or "send and wait failed" in s
                        or "opcode=opcode.auth" in s
                        or "opcode.auth" in s
                    )

                async def _reset_connection():
                    # Аккуратно сбрасываем сокет, чтобы следующий шаг мог переподключиться
                    try:
                        if hasattr(self.client, "_socket") and self.client._socket:
                            try:
                                self.client._socket.close()
                            except Exception:
                                pass
                    finally:
                        self.client.is_connected = False

                # Сначала создаем клиент, если его нет
                if self.client is None:
                    result = self.create_client()
                    if not result.get("success"):
                        return result
                
                # Убеждаемся, что Socket подключен
                if not self.client.is_connected:
                    _dprint("⚠️ Socket not connected, connecting...")
                    try:
                        await self.client.connect(self.client.user_agent)
                        _dprint("✓ Socket connected")
                    except Exception as conn_error:
                        # Если соединение не удалось, пробуем еще раз
                        _dprint(f"✗ Connection failed: {conn_error}, retrying...")
                        await asyncio.sleep(0.5)  # Небольшая задержка перед повтором
                        await self.client.connect(self.client.user_agent)
                        _dprint("✓ Socket connected after retry")
                else:
                    _dprint("✓ Socket already connected")
                
                # Небольшая задержка после подключения для полной инициализации сокета
                await asyncio.sleep(0.2)
                
                # Авторизуемся с кодом с retry
                # ВАЖНО: отправка кода — не идемпотентная операция.
                # Если соединение оборвалось на "send and wait failed", сервер мог получить код,
                # и повторная отправка тем же кодом приводит к "код устарел" / лимиту попыток.
                max_retries = 2  # максимум 1 повтор только для "не подключен" до отправки
                retry_count = 0
                last_error: Optional[Exception] = None

                while retry_count < max_retries:
                    try:
                        _dprint(f"📤 Attempting login with code (attempt {retry_count + 1}/{max_retries})...")

                        # Проверяем соединение перед попыткой
                        if not self.client.is_connected:
                            _dprint("⚠️ Connection lost before login, reconnecting...")
                            await self.client.connect(self.client.user_agent)
                            await asyncio.sleep(0.2)

                        await self.client.login_with_code(temp_token, code, start=False)
                        _dprint("✓ Login successful")
                        last_error = None
                        break
                    except Exception as login_error:
                        last_error = login_error
                        error_type = type(login_error).__name__
                        _dprint(
                            f"✗ Login failed (attempt {retry_count + 1}/{max_retries}): {error_type}: {login_error}"
                        )

                        if _is_code_invalid_error(login_error):
                            # Сервер явно сказал, что код невалиден/устарел/лимит
                            return {
                                "success": False,
                                "requires_new_code": True,
                                "error": str(login_error),
                            }

                        if _is_send_and_wait_error(login_error):
                            # Не повторяем отправку этого же кода
                            await _reset_connection()
                            return {
                                "success": False,
                                "requires_new_code": True,
                                "error": f"{error_type}: Connection dropped while submitting the code. Please request a new code and try again. Details: {login_error}",
                            }

                        # Остальные connection-like ошибки: делаем 1 переподключение и 1 повтор
                        error_str = str(login_error).lower()
                        is_connection_error = (
                            error_type in ["SocketNotConnectedError", "SSLEOFError", "SSLError", "ConnectionError"]
                            or any(keyword in error_str for keyword in ["not connected", "eof", "timeout", "connection"])
                        )

                        if is_connection_error and retry_count < max_retries - 1:
                            retry_count += 1
                            _dprint(f"⚠️ Connection error detected ({error_type}), reconnecting and retrying...")
                            await _reset_connection()
                            await asyncio.sleep(0.5 * retry_count)
                            try:
                                await self.client.connect(self.client.user_agent)
                                await asyncio.sleep(0.2)
                            except Exception as reconnect_error:
                                return {"success": False, "error": f"Reconnection failed: {reconnect_error}"}
                            continue

                        # Неизвестная или не-connection ошибка: не ретраим
                        return {"success": False, "error": str(login_error)}
                
                # Проверяем, успешно ли авторизовались.
                # Важно: `me` может быть не загружен сразу (особенно при start=False),
                # но токен уже валиден — это не должно ломать логин.
                if not getattr(self.client, "_token", None):
                    error_msg = (
                        f"Login failed: token not available: {last_error}"
                        if last_error
                        else "Login failed: token not available"
                    )
                    _dprint(f"✗ {error_msg}")
                    return {"success": False, "error": error_msg}

                # Initialize session right after login so realtime events work without extra UI calls.
                try:
                    await self.client._sync(self.client.user_agent)
                    await self.client._post_login_tasks(sync=False)
                except Exception as e:
                    _dprint(f"Warning: post-login init failed: {e}")

                # Start background keepalive/reconnect loop (best-effort)
                try:
                    await self._ensure_keepalive_started()
                except Exception:
                    pass
                
                # Получаем информацию о текущем пользователе
                me_info = None
                if self.client.me:
                    # Безопасно получаем first_name из names (поддержка и dict/pydantic)
                    first_name = ""
                    names = self._get_field(self.client.me, "names", default=None)
                    if names and isinstance(names, list) and len(names) > 0:
                        n0 = names[0]
                        first_name = (
                            self._get_field(n0, "first_name", "firstName", default=None)
                            or self._get_field(n0, "name", default=None)
                            or ""
                        )

                    me_info = {
                        "id": self._get_field(self.client.me, "id", default=0),
                        "first_name": first_name,  # Всегда строка, даже если пустая
                        "phone": self._get_field(self.client.me, "phone", default=None) or self.phone,
                    }
                return {
                    "success": True,
                    "token": self.client._token,
                    "phone": self.phone,  # Возвращаем номер телефона для сохранения
                    "me": me_info,  # Может быть None, если me еще не загружен
                }
            
            return self._run_async(_login())
        except Exception as e:
            return {"success": False, "error": str(e)}
    
    def get_chats(self) -> Dict[str, Any]:
        """
        Получить список чатов, диалогов и каналов.
        
        :return: Dict со списком всех чатов (dialogs, chats, channels)
        """
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        
        try:
            async def _get_chats():
                # Ensure connected + session initialized (also prevents concurrent connect storms)
                await self._ensure_connected_and_session()

                # Важно: для нормальных имён диалогов нужно подтянуть пользователей по cid.
                # pymax умеет это через get_users() (CONTACT_INFO).
                try:
                    cids = [d.cid for d in self.client.dialogs if getattr(d, "cid", None)]
                    # Убираем дубли и None
                    unique_cids = sorted({int(x) for x in cids if x is not None})
                    if unique_cids:
                        # Загружаем пользователей и ждем завершения
                        await self.client.get_users(unique_cids)
                        # Даем немного времени на обновление кеша
                        await asyncio.sleep(0.1)
                except Exception as e:
                    # best-effort: не ломаем список чатов, если CONTACT_INFO упал
                    _dprint(f"Warning: Failed to load users: {e}")
                    pass
                
                # Собираем все типы чатов: диалоги, чаты и каналы
                # IMPORTANT: IDs can appear in multiple sources (e.g. channels are also in chats list),
                # so we must dedupe by id to keep Swift stable.
                prio = {"DIALOG": 0, "CHAT": 1, "CHANNEL": 2}
                by_id: Dict[int, Dict[str, Any]] = {}

                def _upsert(cd: Dict[str, Any]) -> None:
                    try:
                        cid = int(cd.get("id"))
                    except Exception:
                        return
                    cur = by_id.get(cid)
                    if cur is None:
                        by_id[cid] = cd
                        return
                    cur_type = str(cur.get("type") or "unknown").upper()
                    new_type = str(cd.get("type") or "unknown").upper()
                    if prio.get(new_type, -1) > prio.get(cur_type, -1):
                        by_id[cid] = cd
                        return
                    # Otherwise keep current, but fill missing fields from new.
                    if not (cur.get("title") or "") and (cd.get("title") or ""):
                        cur["title"] = cd.get("title")
                    if cur.get("icon_url") is None and cd.get("icon_url") is not None:
                        cur["icon_url"] = cd.get("icon_url")
                    if cur.get("photo_id") is None and cd.get("photo_id") is not None:
                        cur["photo_id"] = cd.get("photo_id")
                
                # Добавляем диалоги
                for dialog in self.client.dialogs:
                    # Название диалога (обычно имя собеседника)
                    title: str = ""
                    photo_id = None
                    icon_url = None
                    
                    # Determine peer id for dialog.
                    # Prefer participants != me.id (more reliable than cid), fallback to dialog.cid.
                    me_id = self._get_field(self.client.me, "id", default=None) if getattr(self.client, "me", None) else None
                    peer_id = None
                    parts = self._get_field(dialog, "participants", default=None)
                    if me_id is not None and isinstance(parts, dict):
                        try:
                            for k in parts.keys():
                                try:
                                    pid = int(k)
                                except Exception:
                                    continue
                                if int(pid) != int(me_id):
                                    peer_id = int(pid)
                                    break
                        except Exception:
                            peer_id = None

                    if peer_id is None and getattr(dialog, "cid", None) is not None:
                        try:
                            peer_id = int(dialog.cid)
                        except Exception:
                            peer_id = None

                    if peer_id is not None:
                        try:
                            # Получаем пользователя по ID из _users
                            user = self.client._users.get(peer_id)
                            
                            # Если пользователь не найден в кеше, пытаемся загрузить его
                            if user is None:
                                try:
                                    users = await self.client.get_users([peer_id])
                                    if users and len(users) > 0:
                                        user = users[0]
                                        # Обновляем кеш
                                        self.client._users[peer_id] = user
                                except Exception as load_error:
                                    _dprint(f"Warning: Failed to load user {peer_id}: {load_error}")
                            
                            if user is not None:
                                # Пытаемся получить имя из разных источников
                                user_names = self._get_field(user, "names", default=None)
                                if user_names and isinstance(user_names, list) and len(user_names) > 0:
                                    # Проверяем все имена в списке
                                    for name_obj in user_names:
                                        # Пробуем разные варианты полей
                                        name = (
                                            self._get_field(name_obj, "name", default=None)
                                            or self._get_field(name_obj, "first_name", "firstName", default=None)
                                            or None
                                        )
                                        if name and name.strip():
                                            title = name.strip()
                                            break
                                
                                # Если имя не найдено в names, пробуем другие поля
                                if not title:
                                    # Пробуем напрямую из user
                                    title = (
                                        self._get_field(user, "name", default=None)
                                        or self._get_field(user, "first_name", "firstName", default=None)
                                        or None
                                    )
                                    if title:
                                        title = title.strip()
                                
                                # Получаем photo_id
                                photo_id = self._get_field(user, "photo_id", "photoId", default=None)
                                
                                # Получаем base_url для формирования icon_url
                                base_url = self._get_field(user, "base_url", "baseUrl", default=None)
                                base_raw_url = self._get_field(user, "base_raw_url", "baseRawUrl", default=None)
                                # Используем base_url или base_raw_url для icon_url
                                icon_url = base_url or base_raw_url
                                # Cache-buster for avatars as well
                                if icon_url:
                                    try:
                                        sep = "&" if "?" in str(icon_url) else "?"
                                        icon_url = f"{icon_url}{sep}uid={int(peer_id)}"
                                    except Exception:
                                        pass
                        except Exception as e:
                            _dprint(f"Warning: Failed to get user info for peer_id {peer_id}: {e}")
                            pass

                    # Если имя не найдено, используем fallback
                    if not title:
                        title = f"User {peer_id}" if peer_id is not None else f"Dialog {dialog.id}"
                    
                    chat_dict = {
                        "id": dialog.id,
                        "title": title,
                        "type": "DIALOG",
                        "photo_id": photo_id,  # Для диалога берем photo_id из User
                        "icon_url": icon_url,  # Используем base_url из User для отображения фото профиля
                        "unread_count": 0,  # Dialog не имеет unread_count
                        "cid": peer_id,
                    }
                    _upsert(chat_dict)
                
                # Добавляем чаты (группы)
                chat_ids = [chat.id for chat in self.client.chats]
                if chat_ids:
                    chats = await self.client.get_chats(chat_ids)
                    for chat in chats:
                        icon_url = self._get_field(chat, "base_icon_url", "baseIconUrl", default=None)
                        if icon_url:
                            try:
                                sep = "&" if "?" in str(icon_url) else "?"
                                icon_url = f"{icon_url}{sep}chatId={int(chat.id)}"
                            except Exception:
                                pass
                        chat_dict = {
                            "id": chat.id,
                            "title": self._get_field(chat, "title", default="") or "",
                            "type": "CHAT",
                            "photo_id": None,  # Chat не имеет photo_id, использует base_icon_url
                            "icon_url": icon_url,
                            "unread_count": 0,  # Chat не имеет unread_count
                        }
                        _upsert(chat_dict)
                
                # Добавляем каналы (Channel наследуется от Chat)
                for channel in self.client.channels:
                    icon_url = self._get_field(channel, "base_icon_url", "baseIconUrl", default=None)
                    if icon_url:
                        try:
                            sep = "&" if "?" in str(icon_url) else "?"
                            icon_url = f"{icon_url}{sep}chatId={int(channel.id)}"
                        except Exception:
                            pass
                    chat_dict = {
                        "id": channel.id,
                        "title": self._get_field(channel, "title", default="") or "",
                        "type": "CHANNEL",
                        "photo_id": None,  # Channel не имеет photo_id, использует base_icon_url
                        "icon_url": icon_url,
                        "unread_count": 0,  # Channel не имеет unread_count
                    }
                    _upsert(chat_dict)
                
                return {"success": True, "chats": list(by_id.values())}
            
            return self._run_async(_get_chats())
        except Exception as e:
            return {"success": False, "error": str(e)}
    
    def get_messages(self, chat_id: int, limit: int = 50) -> Dict[str, Any]:
        """
        Получить сообщения из чата.
        
        :param chat_id: ID чата
        :param limit: Максимальное количество сообщений
        :return: Dict со списком сообщений
        """
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        
        try:
            async def _get_messages():
                # Вспомогательная функция для переподключения и инициализации сессии
                async def _ensure_connected():
                    """Убедиться, что соединение установлено и сессия инициализирована."""
                    if not self.client.is_connected:
                        _dprint("⚠️ Socket not connected, connecting...")
                        try:
                            # Закрываем старое соединение если есть
                            if hasattr(self.client, '_socket') and self.client._socket:
                                try:
                                    self.client._socket.close()
                                except:
                                    pass
                            self.client.is_connected = False
                            
                            await self.client.connect(self.client.user_agent)
                            _dprint("✓ Socket connected")
                            
                            # Если есть токен, нужно инициализировать сессию
                            if self.client._token:
                                _dprint("⚠️ Token found, initializing session...")
                                await self.client._sync(self.client.user_agent)
                                await self.client._post_login_tasks(sync=False)
                                _dprint("✓ Session initialized")
                        except Exception as conn_error:
                            _dprint(f"✗ Connection failed: {conn_error}, retrying...")
                            # Если соединение не удалось, пробуем еще раз
                            await asyncio.sleep(0.5)
                            await self.client.connect(self.client.user_agent)
                            if self.client._token:
                                await self.client._sync(self.client.user_agent)
                                await self.client._post_login_tasks(sync=False)
                    elif self.client._token and not self.client.me:
                        # Если подключены, но сессия не инициализирована, инициализируем
                        _dprint("⚠️ Socket connected but session not initialized, initializing...")
                        await self.client._sync(self.client.user_agent)
                        await self.client._post_login_tasks(sync=False)
                        _dprint("✓ Session initialized")
                
                # Убеждаемся, что Socket подключен и сессия инициализирована
                await _ensure_connected()
                
                # fetch_history использует backward для количества сообщений
                # Обрабатываем ошибки соединения и переподключаемся при необходимости
                max_retries = 3
                retry_count = 0
                messages = None
                last_error = None
                
                while retry_count < max_retries:
                    try:
                        # Проверяем соединение перед каждой попыткой
                        if not self.client.is_connected:
                            _dprint("⚠️ Connection lost before fetch_history, reconnecting...")
                            await _ensure_connected()
                        
                        messages = await self.client.fetch_history(chat_id=chat_id, backward=limit, forward=0)
                        break  # Успешно получили сообщения
                    except Exception as e:
                        last_error = e
                        error_str = str(e)
                        error_type = type(e).__name__
                        _dprint(
                            f"✗ Error fetching history for chat_id={chat_id} "
                            f"(attempt {retry_count + 1}/{max_retries}): {error_type}: {e}"
                        )
                        
                        # Проверяем, является ли ошибка связанной с соединением
                        # Проверяем по типу исключения (если импортированы) и по строке
                        is_connection_error = (
                            (PYMAX_AVAILABLE and (isinstance(e, SocketNotConnectedError) or isinstance(e, SocketSendError))) or
                            isinstance(e, ssl.SSLEOFError) or
                            isinstance(e, ssl.SSLError) or
                            isinstance(e, ConnectionError) or
                            error_type in ["SocketNotConnectedError", "SocketSendError", "SSLEOFError", "SSLError", "ConnectionError"] or
                            any(keyword in error_str.lower() for keyword in ["not connected", "socket", "eof", "connection", "send and wait failed"])
                        )
                        
                        if is_connection_error:
                            _dprint(f"⚠️ Connection error detected ({error_type}), attempting to reconnect...")
                            retry_count += 1
                            if retry_count < max_retries:
                                try:
                                    # Закрываем старое соединение
                                    if hasattr(self.client, '_socket') and self.client._socket:
                                        try:
                                            self.client._socket.close()
                                        except:
                                            pass
                                    self.client.is_connected = False
                                    
                                    # Переподключаемся с увеличивающейся задержкой
                                    await asyncio.sleep(0.5 * retry_count)
                                    await _ensure_connected()
                                    
                                    _dprint("✓ Reconnected successfully, retrying fetch_history...")
                                    continue  # Пробуем еще раз
                                except Exception as reconnect_error:
                                    _dprint(f"✗ Reconnection failed: {reconnect_error}")
                                    if retry_count >= max_retries:
                                        if _DEBUG:
                                            import traceback
                                            traceback.print_exc()
                                        return {"success": False, "error": f"Failed to reconnect after {max_retries} attempts: {reconnect_error}"}
                            else:
                                # Последняя попытка не удалась
                                if _DEBUG:
                                    import traceback
                                    traceback.print_exc()
                                return {"success": False, "error": f"Failed after {max_retries} reconnection attempts: {e}"}
                        else:
                            # Другие ошибки - не повторяем
                            _dprint(f"✗ Non-connection error, not retrying: {error_type}")
                            if _DEBUG:
                                import traceback
                                traceback.print_exc()
                            return {"success": False, "error": str(e)}
                
                # Если после всех попыток не удалось получить сообщения
                if messages is None:
                    error_msg = f"Failed to fetch messages after {max_retries} attempts: {last_error}" if last_error else "Unknown error"
                    _dprint(f"✗ {error_msg}")
                    return {"success": False, "error": error_msg}
                
                # Проверяем, что сообщения получены
                if messages is None:
                    _dprint(f"⚠️ fetch_history returned None for chat_id={chat_id}")
                    messages = []
                
                _dprint(f"📨 Fetched {len(messages) if messages else 0} messages from API for chat_id={chat_id}")
                
                # Конвертируем в JSON-совместимый формат и сортируем по времени (старые первыми, новые последними)
                messages_list = []
                for msg in (messages or []):
                    msg_dict = self._message_to_dict(msg, fallback_chat_id=chat_id)
                    if msg_dict:
                        messages_list.append(msg_dict)
                
                # Сортируем по времени (старые первыми, новые последними)
                messages_list.sort(key=lambda x: x.get("time", 0) or 0)

                return {"success": True, "messages": messages_list}
            
            return self._run_async(_get_messages())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def send_message(self, chat_id: int, text: str, reply_to: Optional[Any] = None) -> Dict[str, Any]:
        """Отправить сообщение в чат."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}

        reply_to_int = self._coerce_int(reply_to)

        try:
            async def _send():
                await self._ensure_connected_and_session()
                msg = await self.client.send_message(
                    text=text,
                    chat_id=chat_id,
                    reply_to=reply_to_int,
                    notify=True,
                )
                msg_dict = self._message_to_dict(msg, fallback_chat_id=chat_id)
                if not msg_dict:
                    return {"success": False, "error": "Invalid message response"}
                return {"success": True, "message": msg_dict}

            return self._run_async(_send())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def edit_message(self, chat_id: int, message_id: Any, text: str) -> Dict[str, Any]:
        """Редактировать сообщение."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}

        message_id_int = self._coerce_int(message_id)
        if message_id_int is None:
            return {"success": False, "error": "Invalid message_id"}

        try:
            async def _edit():
                await self._ensure_connected_and_session()
                msg = await self.client.edit_message(
                    chat_id=chat_id,
                    message_id=message_id_int,
                    text=text,
                )
                msg_dict = self._message_to_dict(msg, fallback_chat_id=chat_id)
                if not msg_dict:
                    return {"success": False, "error": "Invalid message response"}
                return {"success": True, "message": msg_dict}

            return self._run_async(_edit())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def delete_message(self, chat_id: int, message_ids: Any, for_me: bool = True) -> Dict[str, Any]:
        """Удалить одно или несколько сообщений."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}

        ids = self._coerce_int_list(message_ids)
        if not ids:
            return {"success": False, "error": "Invalid message_ids"}

        try:
            async def _delete():
                await self._ensure_connected_and_session()
                ok = await self.client.delete_message(
                    chat_id=chat_id,
                    message_ids=ids,
                    for_me=for_me,
                )
                return {"success": True, "deleted": bool(ok), "message_ids": [str(i) for i in ids]}

            return self._run_async(_delete())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def pin_message(self, chat_id: int, message_id: Any, notify_pin: bool = True) -> Dict[str, Any]:
        """Закрепить сообщение."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}

        message_id_int = self._coerce_int(message_id)
        if message_id_int is None:
            return {"success": False, "error": "Invalid message_id"}

        try:
            async def _pin():
                await self._ensure_connected_and_session()
                ok = await self.client.pin_message(chat_id=chat_id, message_id=message_id_int, notify_pin=notify_pin)
                return {"success": True, "pinned": bool(ok), "message_id": str(message_id_int)}

            return self._run_async(_pin())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def add_reaction(self, chat_id: int, message_id: Any, reaction: str) -> Dict[str, Any]:
        """Добавить реакцию (emoji) к сообщению."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}

        # pymax ожидает message_id: str
        msg_id_str = str(message_id) if message_id is not None else ""
        if not msg_id_str:
            return {"success": False, "error": "Invalid message_id"}

        try:
            async def _add():
                await self._ensure_connected_and_session()
                info = await self.client.add_reaction(chat_id=chat_id, message_id=msg_id_str, reaction=reaction)
                info_dict = self._reaction_info_to_dict(info)
                return {"success": True, "reaction_info": info_dict}

            return self._run_async(_add())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def remove_reaction(self, chat_id: int, message_id: Any) -> Dict[str, Any]:
        """Удалить свою реакцию с сообщения."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}

        msg_id_str = str(message_id) if message_id is not None else ""
        if not msg_id_str:
            return {"success": False, "error": "Invalid message_id"}

        try:
            async def _remove():
                await self._ensure_connected_and_session()
                info = await self.client.remove_reaction(chat_id=chat_id, message_id=msg_id_str)
                info_dict = self._reaction_info_to_dict(info)
                return {"success": True, "reaction_info": info_dict}

            return self._run_async(_remove())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def upload_photo(self, file_path: str) -> Dict[str, Any]:
        """Загрузить фото и вернуть attach payload (photo_token) для последующей отправки."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if Photo is None:
            return {"success": False, "error": "pymax Photo not available"}
        if not file_path or not os.path.exists(file_path):
            return {"success": False, "error": "File not found"}

        try:
            async def _upload():
                await self._ensure_connected_and_session()
                attach = await self.client._upload_attachment(Photo(path=file_path))
                if not attach:
                    return {"success": False, "error": "Upload failed"}
                # attach is a dict, typically contains photoToken
                photo_token = None
                if isinstance(attach, dict):
                    photo_token = attach.get("photoToken") or attach.get("photo_token")
                return {"success": True, "attach": attach, "photo_token": photo_token}

            return self._run_async(_upload())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def upload_file(self, file_path: str) -> Dict[str, Any]:
        """Загрузить файл и вернуть attach payload (file_id) для последующей отправки."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if File is None:
            return {"success": False, "error": "pymax File not available"}
        if not file_path or not os.path.exists(file_path):
            return {"success": False, "error": "File not found"}

        try:
            async def _upload():
                await self._ensure_connected_and_session()
                attach = await self.client._upload_attachment(File(path=file_path))
                if not attach:
                    return {"success": False, "error": "Upload failed"}
                file_id = None
                if isinstance(attach, dict):
                    file_id = attach.get("fileId") or attach.get("file_id")
                return {"success": True, "attach": attach, "file_id": file_id}

            return self._run_async(_upload())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def send_attachment(
        self,
        chat_id: int,
        file_path: str,
        attachment_type: str = "file",
        text: str = "",
        reply_to: Optional[Any] = None,
        notify: bool = True,
    ) -> Dict[str, Any]:
        """Отправить вложение (photo/file) в чат без запроса доступов к галерее (Swift передаёт локальный temp path)."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not file_path or not os.path.exists(file_path):
            return {"success": False, "error": "File not found"}

        at = (attachment_type or "file").lower().strip()
        reply_to_int = self._coerce_int(reply_to)

        try:
            async def _send():
                await self._ensure_connected_and_session()

                attachment_obj = None
                if at in ("photo", "image", "img"):
                    if Photo is None:
                        return {"success": False, "error": "pymax Photo not available"}
                    attachment_obj = Photo(path=file_path)
                else:
                    if File is None:
                        return {"success": False, "error": "pymax File not available"}
                    attachment_obj = File(path=file_path)

                msg = await self.client.send_message(
                    text=text or "",
                    chat_id=chat_id,
                    notify=notify,
                    attachment=attachment_obj,
                    reply_to=reply_to_int,
                )
                msg_dict = self._message_to_dict(msg, fallback_chat_id=chat_id)
                if not msg_dict:
                    return {"success": False, "error": "Invalid message response"}
                return {"success": True, "message": msg_dict}

            return self._run_async(_send())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def change_profile(
        self,
        first_name: str,
        last_name: Optional[str] = None,
        description: Optional[str] = None,
        photo_path: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Изменить профиль текущего пользователя (имя/описание/аватар)."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not first_name:
            return {"success": False, "error": "first_name required"}

        photo_obj = None
        if photo_path:
            if Photo is None:
                return {"success": False, "error": "pymax Photo not available"}
            if not os.path.exists(photo_path):
                return {"success": False, "error": "Photo file not found"}
            photo_obj = Photo(path=photo_path)

        try:
            async def _change():
                await self._ensure_connected_and_session()
                ok = await self.client.change_profile(
                    first_name=first_name,
                    last_name=last_name,
                    description=description,
                    photo=photo_obj,
                )
                me_info = None
                if getattr(self.client, "me", None):
                    names = self._get_field(self.client.me, "names", default=None)
                    first = ""
                    if names and isinstance(names, list) and len(names) > 0:
                        n0 = names[0]
                        first = (
                            self._get_field(n0, "first_name", "firstName", default=None)
                            or self._get_field(n0, "name", default=None)
                            or ""
                        )
                    me_info = {
                        "id": self._get_field(self.client.me, "id", default=0),
                        "first_name": first,
                        "phone": self._get_field(self.client.me, "phone", default=None) or self.phone,
                    }
                return {"success": True, "updated": bool(ok), "me": me_info}

            return self._run_async(_change())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def get_folders(self, folder_sync: int = 0) -> Dict[str, Any]:
        """Получить папки (folders) пользователя."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        try:
            async def _get():
                await self._ensure_connected_and_session()
                fl = await self.client.get_folders(folder_sync=folder_sync)
                # best-effort serialization
                folders = []
                for f in getattr(fl, "folders", []) or []:
                    folders.append(
                        {
                            "id": self._get_field(f, "id", default=None),
                            "title": self._get_field(f, "title", default="") or "",
                            "include": self._get_field(f, "include", default=[]) or [],
                        }
                    )
                return {"success": True, "folders": folders}

            return self._run_async(_get())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def fetch_chats(self, marker: Optional[int] = None) -> Dict[str, Any]:
        """Загрузить список чатов с сервера (CHATS_LIST)."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        try:
            async def _fetch():
                await self._ensure_connected_and_session()
                chats = await self.client.fetch_chats(marker=marker)
                out = []
                for chat in chats or []:
                    out.append(
                        {
                            "id": self._get_field(chat, "id", default=None),
                            "title": self._get_field(chat, "title", default="") or "",
                            "type": "CHAT",
                            "icon_url": self._get_field(chat, "base_icon_url", "baseIconUrl", default=None),
                        }
                    )
                return {"success": True, "chats": out}

            return self._run_async(_fetch())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def search_by_phone(self, phone: str) -> Dict[str, Any]:
        """Поиск пользователя по номеру телефона."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not phone:
            return {"success": False, "error": "phone required"}

        try:
            async def _search():
                await self._ensure_connected_and_session()
                user = await self.client.search_by_phone(phone)
                names = self._get_field(user, "names", default=None)
                display = None
                if names and isinstance(names, list) and len(names) > 0:
                    n0 = names[0]
                    display = (
                        self._get_field(n0, "name", default=None)
                        or self._get_field(n0, "first_name", "firstName", default=None)
                    )
                return {
                    "success": True,
                    "user": {
                        "id": self._get_field(user, "id", default=None),
                        "name": display or "",
                        "photo_id": self._get_field(user, "photo_id", "photoId", default=None),
                        "phone": self._get_field(user, "phone", default=None),
                    },
                }

            return self._run_async(_search())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def resolve_channel_by_name(self, name: str) -> Dict[str, Any]:
        """Разрешить канал по @name (https://max.ru/<name>)."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not name:
            return {"success": False, "error": "name required"}
        n = name.lstrip("@").strip()
        if not n:
            return {"success": False, "error": "name required"}

        try:
            async def _resolve():
                await self._ensure_connected_and_session()
                ch = await self.client.resolve_channel_by_name(n)
                if ch is None:
                    return {"success": False, "error": "Channel not found"}
                return {
                    "success": True,
                    "channel": {
                        "id": self._get_field(ch, "id", default=None),
                        "title": self._get_field(ch, "title", default="") or "",
                        "icon_url": self._get_field(ch, "base_icon_url", "baseIconUrl", default=None),
                    },
                }

            return self._run_async(_resolve())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def create_folder(self, title: str, chat_include: Any) -> Dict[str, Any]:
        """Создать папку (folder) для группировки чатов."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not title:
            return {"success": False, "error": "title required"}
        include = self._coerce_int_list(chat_include)
        if include is None:
            include = []

        try:
            async def _create():
                await self._ensure_connected_and_session()
                upd = await self.client.create_folder(title=title, chat_include=include, filters=None)
                folder = getattr(upd, "folder", None)
                return {
                    "success": True,
                    "folder": {
                        "id": self._get_field(folder, "id", default=None),
                        "title": self._get_field(folder, "title", default="") or "",
                        "include": self._get_field(folder, "include", default=[]) or [],
                    },
                }

            return self._run_async(_create())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def update_folder(self, folder_id: str, title: str, chat_include: Any = None) -> Dict[str, Any]:
        """Обновить папку."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not folder_id:
            return {"success": False, "error": "folder_id required"}
        if not title:
            return {"success": False, "error": "title required"}
        include = self._coerce_int_list(chat_include) if chat_include is not None else None

        try:
            async def _update():
                await self._ensure_connected_and_session()
                upd = await self.client.update_folder(
                    folder_id=folder_id,
                    title=title,
                    chat_include=include,
                    filters=None,
                    options=None,
                )
                folder = getattr(upd, "folder", None) if upd is not None else None
                return {
                    "success": True,
                    "folder": {
                        "id": self._get_field(folder, "id", default=None),
                        "title": self._get_field(folder, "title", default="") or "",
                        "include": self._get_field(folder, "include", default=[]) or [],
                    },
                }

            return self._run_async(_update())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def delete_folder(self, folder_id: str) -> Dict[str, Any]:
        """Удалить папку."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not folder_id:
            return {"success": False, "error": "folder_id required"}
        try:
            async def _delete():
                await self._ensure_connected_and_session()
                upd = await self.client.delete_folder(folder_id=folder_id)
                return {"success": True, "deleted": True, "folder_id": folder_id}

            return self._run_async(_delete())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def join_group(self, link: str) -> Dict[str, Any]:
        """Вступить в группу по ссылке."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not link:
            return {"success": False, "error": "link required"}
        try:
            async def _join():
                await self._ensure_connected_and_session()
                chat = await self.client.join_group(link)
                return {
                    "success": True,
                    "chat": {
                        "id": self._get_field(chat, "id", default=None),
                        "title": self._get_field(chat, "title", default="") or "",
                        "type": "CHAT",
                        "icon_url": self._get_field(chat, "base_icon_url", "baseIconUrl", default=None),
                    },
                }

            return self._run_async(_join())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def join_channel(self, link: str) -> Dict[str, Any]:
        """Вступить в канал по ссылке."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        if not link:
            return {"success": False, "error": "link required"}
        try:
            async def _join():
                # Join is sensitive to session state; do a couple of best-effort retries after reconnect.
                last_err: Optional[Exception] = None
                for attempt in range(3):
                    try:
                        await self._ensure_connected_and_session()
                        ch = await self.client.join_channel(link)
                        if ch is None:
                            return {"success": False, "error": "Channel not found"}
                        return {
                            "success": True,
                            "chat": {
                                "id": self._get_field(ch, "id", default=None),
                                "title": self._get_field(ch, "title", default="") or "",
                                "type": "CHANNEL",
                                "icon_url": self._get_field(ch, "base_icon_url", "baseIconUrl", default=None),
                            },
                        }
                    except Exception as e:
                        last_err = e
                        # Connection/session-like errors: cleanup+retry
                        s = str(e).lower()
                        et = type(e).__name__.lower()
                        is_conn = (
                            "not connected" in s
                            or "connection" in s
                            or "send and wait failed" in s
                            or "session" in s and "online" in s
                            or et in ["socketnotconnectederror", "socketsenderror", "sslerror", "ssleoferror"]
                        )
                        if attempt < 2 and is_conn:
                            try:
                                if hasattr(self.client, "_cleanup_client"):
                                    await self.client._cleanup_client()
                            except Exception:
                                pass
                            await asyncio.sleep(0.6 * (attempt + 1))
                            continue
                        break

                return {"success": False, "error": str(last_err) if last_err else "Join failed"}

            return self._run_async(_join())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def leave_group(self, chat_id: int) -> Dict[str, Any]:
        """Покинуть группу."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        try:
            async def _leave():
                await self._ensure_connected_and_session()
                await self.client.leave_group(chat_id)
                return {"success": True, "left": True, "chat_id": chat_id}

            return self._run_async(_leave())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def leave_channel(self, chat_id: int) -> Dict[str, Any]:
        """Покинуть канал."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        try:
            async def _leave():
                await self._ensure_connected_and_session()
                await self.client.leave_channel(chat_id)
                return {"success": True, "left": True, "chat_id": chat_id}

            return self._run_async(_leave())
        except Exception as e:
            return {"success": False, "error": str(e)}

    def read_message(self, chat_id: int, message_id: Any) -> Dict[str, Any]:
        """Отметить сообщение как прочитанное."""
        if self.client is None:
            return {"success": False, "error": "Client not initialized"}
        msg_int = self._coerce_int(message_id)
        if msg_int is None:
            return {"success": False, "error": "Invalid message_id"}
        try:
            async def _read():
                await self._ensure_connected_and_session()
                state = await self.client.read_message(message_id=msg_int, chat_id=chat_id)
                return {"success": True, "state": {"chat_id": chat_id, "message_id": str(msg_int)}}

            return self._run_async(_read())
        except Exception as e:
            return {"success": False, "error": str(e)}
    
    def start_client(self) -> Dict[str, Any]:
        """
        Запустить клиент (подключиться и авторизоваться).
        
        :return: Dict с результатом запуска
        """
        if self.client is None:
            result = self.create_client()
            if not result.get("success"):
                return result
        
        try:
            async def _start():
                # Ensure connected/session (sync/post-login) and start keepalive for realtime events.
                await self._ensure_connected_and_session()
                try:
                    await self._ensure_keepalive_started()
                except Exception:
                    pass
                    
                # Если есть сохраненный токен, используем его для синхронизации
                if self.client._token:
                    # Получаем информацию о пользователе
                    me_info = None
                    if self.client.me:
                        # Безопасно получаем first_name из names (поддержка и dict/pydantic)
                        first_name = ""
                        names = self._get_field(self.client.me, "names", default=None)
                        if names and isinstance(names, list) and len(names) > 0:
                            n0 = names[0]
                            first_name = (
                                self._get_field(n0, "first_name", "firstName", default=None)
                                or self._get_field(n0, "name", default=None)
                                or ""
                            )

                        me_info = {
                            "id": self._get_field(self.client.me, "id", default=0),
                            "first_name": first_name,  # Всегда строка, даже если пустая
                            "phone": self._get_field(self.client.me, "phone", default=None) or self.phone,
                        }
                    
                    return {
                        "success": True,
                        "connected": self.client.is_connected,
                        "authenticated": True,
                        "me": me_info,
                    }
                else:
                    return {
                        "success": True,
                        "connected": self.client.is_connected,
                        "authenticated": False,
                        "requires_auth": True,
                    }
            
            return self._run_async(_start())
        except Exception as e:
            return {"success": False, "error": str(e)}
    
    def stop_client(self) -> Dict[str, Any]:
        """
        Остановить клиент.
        
        :return: Dict с результатом остановки
        """
        if self.client is None:
            return {"success": True, "message": "Client not initialized"}
        
        try:
            async def _stop():
                # Stop keepalive loop first
                if self._keepalive_stop is not None:
                    try:
                        self._keepalive_stop.set()
                    except Exception:
                        pass
                if self._keepalive_task is not None:
                    self._keepalive_task.cancel()
                    try:
                        await self._keepalive_task
                    except Exception:
                        pass
                    self._keepalive_task = None
                await self.client.close()
                return {"success": True, "message": "Client stopped"}
            
            result = self._run_async(_stop())
            # Also stop asyncio loop thread to avoid dangling tasks on shutdown.
            self._stop_loop_thread()
            return result
        except Exception as e:
            return {"success": False, "error": str(e)}


# Глобальный экземпляр для использования из Swift
_wrapper_instance: Optional[MaxClientWrapper] = None


def create_wrapper(phone: str, work_dir: Optional[str] = None, token: Optional[str] = None) -> str:
    """Создать глобальный экземпляр обертки."""
    global _wrapper_instance
    if not PYMAX_AVAILABLE:
        return json.dumps(
            {
                "success": False,
                "error": "pymax not available - missing dependencies",
                "details": _PYMAX_IMPORT_ERROR,
            }
        )
    try:
        _wrapper_instance = MaxClientWrapper(phone, work_dir, token)
        return json.dumps({"success": True})
    except RuntimeError as e:
        if "pymax not available" in str(e):
            return json.dumps(
                {
                    "success": False,
                    "error": "pymax not available - missing dependencies",
                    "details": _PYMAX_IMPORT_ERROR or str(e),
                }
            )
        return json.dumps({"success": False, "error": str(e)})
    except Exception as e:
        return json.dumps({"success": False, "error": str(e)})


def request_code(phone: Optional[str] = None, language: str = "ru") -> str:
    """Запросить код авторизации."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.request_code(phone, language)
    return json.dumps(result)


def login_with_code(temp_token: str, code: str) -> str:
    """Авторизоваться с кодом."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.login_with_code(temp_token, code)
    return json.dumps(result)


def get_chats() -> str:
    """Получить список чатов."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.get_chats()
    return json.dumps(result)


def get_messages(chat_id: int, limit: int = 50) -> str:
    """Получить сообщения из чата."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.get_messages(chat_id, limit)
    return json.dumps(result)


def start_client() -> str:
    """Запустить клиент."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.start_client()
    return json.dumps(result)


def stop_client() -> str:
    """Остановить клиент."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": True, "message": "Wrapper not initialized"})
    result = _wrapper_instance.stop_client()
    return json.dumps(result)


def send_message(chat_id: int, text: str, reply_to: Optional[Any] = None) -> str:
    """Отправить сообщение в чат."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.send_message(chat_id, text, reply_to)
    return json.dumps(result)


def send_attachment(
    chat_id: int,
    file_path: str,
    attachment_type: str = "file",
    text: str = "",
    reply_to: Optional[Any] = None,
    notify: bool = True,
) -> str:
    """Send photo/file attachment."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.send_attachment(chat_id, file_path, attachment_type, text, reply_to, notify)
    return json.dumps(result)


def edit_message(chat_id: int, message_id: Any, text: str) -> str:
    """Редактировать сообщение."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.edit_message(chat_id, message_id, text)
    return json.dumps(result)


def delete_message(chat_id: int, message_ids: Any, for_me: bool = True) -> str:
    """Удалить сообщения."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.delete_message(chat_id, message_ids, for_me)
    return json.dumps(result)


def pin_message(chat_id: int, message_id: Any, notify_pin: bool = True) -> str:
    """Закрепить сообщение."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.pin_message(chat_id, message_id, notify_pin)
    return json.dumps(result)


def add_reaction(chat_id: int, message_id: Any, reaction: str) -> str:
    """Добавить реакцию."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.add_reaction(chat_id, message_id, reaction)
    return json.dumps(result)


def remove_reaction(chat_id: int, message_id: Any) -> str:
    """Удалить свою реакцию."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.remove_reaction(chat_id, message_id)
    return json.dumps(result)


def upload_photo(file_path: str) -> str:
    """Загрузить фото и вернуть attach payload."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.upload_photo(file_path)
    return json.dumps(result)


def upload_file(file_path: str) -> str:
    """Загрузить файл и вернуть attach payload."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.upload_file(file_path)
    return json.dumps(result)


def get_events_dir() -> str:
    """Получить директорию, куда пишем события."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.get_events_dir()
    return json.dumps(result)


def register_event_callbacks(events_dir: Optional[str] = None) -> str:
    """Зарегистрировать callbacks для real-time событий."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.register_event_callbacks(events_dir)
    return json.dumps(result)


def change_profile(first_name: str, last_name: Optional[str] = None, description: Optional[str] = None, photo_path: Optional[str] = None) -> str:
    """Изменить профиль."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.change_profile(first_name, last_name, description, photo_path)
    return json.dumps(result)


def get_folders(folder_sync: int = 0) -> str:
    """Получить папки."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.get_folders(folder_sync)
    return json.dumps(result)


def fetch_chats(marker: Optional[int] = None) -> str:
    """Загрузить список чатов с сервера."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.fetch_chats(marker)
    return json.dumps(result)


def search_by_phone(phone: str) -> str:
    """Поиск пользователя по телефону."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.search_by_phone(phone)
    return json.dumps(result)


def resolve_channel_by_name(name: str) -> str:
    """Resolve channel by @name."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.resolve_channel_by_name(name)
    return json.dumps(result)


def create_folder(title: str, chat_include: Any) -> str:
    """Create folder."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.create_folder(title, chat_include)
    return json.dumps(result)


def update_folder(folder_id: str, title: str, chat_include: Any = None) -> str:
    """Update folder."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.update_folder(folder_id, title, chat_include)
    return json.dumps(result)


def delete_folder(folder_id: str) -> str:
    """Delete folder."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.delete_folder(folder_id)
    return json.dumps(result)


def join_group(link: str) -> str:
    """Join group by invite link."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.join_group(link)
    return json.dumps(result)


def join_channel(link: str) -> str:
    """Join channel by link."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.join_channel(link)
    return json.dumps(result)


def leave_group(chat_id: int) -> str:
    """Leave group."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.leave_group(chat_id)
    return json.dumps(result)


def leave_channel(chat_id: int) -> str:
    """Leave channel."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.leave_channel(chat_id)
    return json.dumps(result)


def read_message(chat_id: int, message_id: Any) -> str:
    """Mark message as read."""
    global _wrapper_instance
    if _wrapper_instance is None:
        return json.dumps({"success": False, "error": "Wrapper not initialized"})
    result = _wrapper_instance.read_message(chat_id, message_id)
    return json.dumps(result)
