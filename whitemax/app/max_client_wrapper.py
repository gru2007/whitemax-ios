"""
Python обертка для Swift для работы с pymax.
Обеспечивает синхронный интерфейс для асинхронного pymax клиента.
"""

import asyncio
import datetime
import json
import os
import ssl
import sys
from typing import Any, Dict, List, Optional

# Добавляем текущую директорию в sys.path для поиска модулей
_current_dir = os.path.dirname(os.path.abspath(__file__))
if _current_dir not in sys.path:
    sys.path.insert(0, _current_dir)

PYMAX_AVAILABLE = False
try:
    # Пытаемся импортировать pymax
    # Для iOS используем SocketMaxClient вместо MaxClient
    from pymax import SocketMaxClient
    from pymax.payloads import UserAgentPayload
    from pymax.types import Chat, Message
    from pymax.exceptions import SocketNotConnectedError, SocketSendError
    PYMAX_AVAILABLE = True
    print("✓ pymax imported successfully")
except ImportError as e:
    # Если импорт не удался, создаем заглушки для типов
    import sys
    import os
    import traceback
    
    print(f"Warning: Failed to import pymax: {e}")
    print(f"Error type: {type(e).__name__}")
    print(f"Python path: {sys.path}")
    
    # Проверяем наличие pymax
    app_dir = os.path.dirname(os.path.abspath(__file__))
    pymax_dir = os.path.join(app_dir, "pymax")
    print(f"Looking for pymax at: {pymax_dir}")
    print(f"pymax exists: {os.path.exists(pymax_dir)}")
    
    # Проверяем наличие __init__.py
    pymax_init = os.path.join(pymax_dir, "__init__.py")
    if os.path.exists(pymax_init):
        print(f"✓ pymax/__init__.py exists")
    else:
        print(f"✗ pymax/__init__.py NOT found")
    
    # Выводим полный traceback для диагностики
    print("Full traceback:")
    traceback.print_exc()
    
    # Устанавливаем заглушки
    SocketMaxClient = None
    UserAgentPayload = None
    Chat = None
    Message = None


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
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        
    def _get_loop(self) -> asyncio.AbstractEventLoop:
        """Получить или создать event loop."""
        if self._loop is None or self._loop.is_closed():
            try:
                self._loop = asyncio.get_event_loop()
            except RuntimeError:
                self._loop = asyncio.new_event_loop()
                asyncio.set_event_loop(self._loop)
        return self._loop
    
    def _run_async(self, coro):
        """Запустить асинхронную функцию синхронно."""
        # Для стабильной работы SocketMaxClient важно переиспользовать один event loop,
        # иначе объекты сокета/transport могут оказаться привязаны к закрытому loop.
        loop = self._get_loop()
        try:
            if loop.is_running():
                # Если loop уже запущен в текущем потоке, то запускаем coro в отдельном потоке
                # через asyncio.run(). (Редкий кейс для нашей интеграции, но пусть будет безопасно.)
                import concurrent.futures

                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                    future = executor.submit(asyncio.run, coro)
                    return future.result(timeout=60)  # Таймаут 60 секунд

            # Обычный синхронный вызов: выполняем coroutine в нашем стабильном loop
            asyncio.set_event_loop(loop)
            return loop.run_until_complete(coro)
        except Exception as e:
            print(f"Error in _run_async: {e}")
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
                    print(f"⚠️ Socket not connected, connecting...")
                    try:
                        await self.client.connect(self.client.user_agent)
                        print(f"✓ Socket connected")
                    except Exception as conn_error:
                        # Если соединение не удалось, пробуем еще раз
                        print(f"✗ Connection failed: {conn_error}, retrying...")
                        await asyncio.sleep(0.5)  # Небольшая задержка перед повтором
                        await self.client.connect(self.client.user_agent)
                        print(f"✓ Socket connected after retry")
                else:
                    print(f"✓ Socket already connected")
                
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
                        print(f"📤 Attempting login with code (attempt {retry_count + 1}/{max_retries})...")

                        # Проверяем соединение перед попыткой
                        if not self.client.is_connected:
                            print(f"⚠️ Connection lost before login, reconnecting...")
                            await self.client.connect(self.client.user_agent)
                            await asyncio.sleep(0.2)

                        await self.client.login_with_code(temp_token, code, start=False)
                        print(f"✓ Login successful")
                        last_error = None
                        break
                    except Exception as login_error:
                        last_error = login_error
                        error_type = type(login_error).__name__
                        print(f"✗ Login failed (attempt {retry_count + 1}/{max_retries}): {error_type}: {login_error}")

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
                            print(f"⚠️ Connection error detected ({error_type}), reconnecting and retrying...")
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
                    print(f"✗ {error_msg}")
                    return {"success": False, "error": error_msg}
                
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
                # Убеждаемся, что Socket подключен
                if not self.client.is_connected:
                    try:
                        await self.client.connect(self.client.user_agent)
                        # Если есть токен, нужно инициализировать сессию
                        if self.client._token:
                            await self.client._sync(self.client.user_agent)
                            await self.client._post_login_tasks(sync=False)
                    except Exception as conn_error:
                        # Если соединение не удалось, пробуем еще раз
                        await asyncio.sleep(0.5)
                        await self.client.connect(self.client.user_agent)
                        if self.client._token:
                            await self.client._sync(self.client.user_agent)
                            await self.client._post_login_tasks(sync=False)
                elif self.client._token and not self.client.me:
                    # Если подключены, но сессия не инициализирована, инициализируем
                    await self.client._sync(self.client.user_agent)
                    await self.client._post_login_tasks(sync=False)
                
                # Собираем все типы чатов: диалоги, чаты и каналы
                all_chats = []
                
                # Добавляем диалоги
                for dialog in self.client.dialogs:
                    # Получаем название диалога (обычно имя собеседника)
                    title = f"Dialog {dialog.id}"
                    photo_id = None
                    
                    # Пытаемся получить имя из участников
                    # Для диалога cid обычно ID собеседника
                    if dialog.cid:
                        try:
                            # Получаем пользователя по ID из _users
                            if dialog.cid in self.client._users:
                                user = self.client._users[dialog.cid]
                                user_names = self._get_field(user, "names", default=None)
                                if user_names and isinstance(user_names, list) and len(user_names) > 0:
                                    n0 = user_names[0]
                                    title = (
                                        self._get_field(n0, "name", default=None)
                                        or self._get_field(n0, "first_name", "firstName", default=None)
                                        or f"User {dialog.cid}"
                                    )
                                photo_id = self._get_field(user, "photo_id", "photoId", default=None)
                        except Exception:
                            pass
                    
                    chat_dict = {
                        "id": dialog.id,
                        "title": title,
                        "type": "DIALOG",
                        "photo_id": photo_id,  # Для диалога берем photo_id из User
                        "icon_url": None,  # Dialog не имеет icon_url
                        "unread_count": 0,  # Dialog не имеет unread_count
                        "cid": dialog.cid,
                    }
                    all_chats.append(chat_dict)
                
                # Добавляем чаты (группы)
                chat_ids = [chat.id for chat in self.client.chats]
                if chat_ids:
                    chats = await self.client.get_chats(chat_ids)
                    for chat in chats:
                        chat_dict = {
                            "id": chat.id,
                            "title": self._get_field(chat, "title", default="") or "",
                            "type": "CHAT",
                            "photo_id": None,  # Chat не имеет photo_id, использует base_icon_url
                            "icon_url": self._get_field(chat, "base_icon_url", "baseIconUrl", default=None),
                            "unread_count": 0,  # Chat не имеет unread_count
                        }
                        all_chats.append(chat_dict)
                
                # Добавляем каналы (Channel наследуется от Chat)
                for channel in self.client.channels:
                    chat_dict = {
                        "id": channel.id,
                        "title": self._get_field(channel, "title", default="") or "",
                        "type": "CHANNEL",
                        "photo_id": None,  # Channel не имеет photo_id, использует base_icon_url
                        "icon_url": self._get_field(channel, "base_icon_url", "baseIconUrl", default=None),
                        "unread_count": 0,  # Channel не имеет unread_count
                    }
                    all_chats.append(chat_dict)
                
                return {"success": True, "chats": all_chats}
            
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
                        print(f"⚠️ Socket not connected, connecting...")
                        try:
                            # Закрываем старое соединение если есть
                            if hasattr(self.client, '_socket') and self.client._socket:
                                try:
                                    self.client._socket.close()
                                except:
                                    pass
                            self.client.is_connected = False
                            
                            await self.client.connect(self.client.user_agent)
                            print(f"✓ Socket connected")
                            
                            # Если есть токен, нужно инициализировать сессию
                            if self.client._token:
                                print(f"⚠️ Token found, initializing session...")
                                await self.client._sync(self.client.user_agent)
                                await self.client._post_login_tasks(sync=False)
                                print(f"✓ Session initialized")
                        except Exception as conn_error:
                            print(f"✗ Connection failed: {conn_error}, retrying...")
                            # Если соединение не удалось, пробуем еще раз
                            await asyncio.sleep(0.5)
                            await self.client.connect(self.client.user_agent)
                            if self.client._token:
                                await self.client._sync(self.client.user_agent)
                                await self.client._post_login_tasks(sync=False)
                    elif self.client._token and not self.client.me:
                        # Если подключены, но сессия не инициализирована, инициализируем
                        print(f"⚠️ Socket connected but session not initialized, initializing...")
                        await self.client._sync(self.client.user_agent)
                        await self.client._post_login_tasks(sync=False)
                        print(f"✓ Session initialized")
                
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
                            print(f"⚠️ Connection lost before fetch_history, reconnecting...")
                            await _ensure_connected()
                        
                        messages = await self.client.fetch_history(chat_id=chat_id, backward=limit, forward=0)
                        break  # Успешно получили сообщения
                    except Exception as e:
                        last_error = e
                        error_str = str(e)
                        error_type = type(e).__name__
                        print(f"✗ Error fetching history for chat_id={chat_id} (attempt {retry_count + 1}/{max_retries}): {error_type}: {e}")
                        
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
                            print(f"⚠️ Connection error detected ({error_type}), attempting to reconnect...")
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
                                    
                                    print(f"✓ Reconnected successfully, retrying fetch_history...")
                                    continue  # Пробуем еще раз
                                except Exception as reconnect_error:
                                    print(f"✗ Reconnection failed: {reconnect_error}")
                                    if retry_count >= max_retries:
                                        import traceback
                                        traceback.print_exc()
                                        return {"success": False, "error": f"Failed to reconnect after {max_retries} attempts: {reconnect_error}"}
                            else:
                                # Последняя попытка не удалась
                                import traceback
                                traceback.print_exc()
                                return {"success": False, "error": f"Failed after {max_retries} reconnection attempts: {e}"}
                        else:
                            # Другие ошибки - не повторяем
                            print(f"✗ Non-connection error, not retrying: {error_type}")
                            import traceback
                            traceback.print_exc()
                            return {"success": False, "error": str(e)}
                
                # Если после всех попыток не удалось получить сообщения
                if messages is None:
                    error_msg = f"Failed to fetch messages after {max_retries} attempts: {last_error}" if last_error else "Unknown error"
                    print(f"✗ {error_msg}")
                    return {"success": False, "error": error_msg}
                
                # Проверяем, что сообщения получены
                if messages is None:
                    print(f"⚠️ fetch_history returned None for chat_id={chat_id}")
                    messages = []
                
                print(f"📨 Fetched {len(messages) if messages else 0} messages from API for chat_id={chat_id}")
                
                # Конвертируем в JSON-совместимый формат и сортируем по времени (старые первыми, новые последними)
                messages_list = []
                for idx, msg in enumerate(messages or []):
                    try:
                        # Безопасно получаем атрибуты сообщения
                        msg_id = getattr(msg, 'id', None)
                        if msg_id is None:
                            print(f"⚠️ Message {idx} has no id, skipping")
                            continue
                        
                        msg_text = getattr(msg, 'text', '') or ""
                        msg_time = getattr(msg, 'time', None)
                        msg_time_ms = self._normalize_time_to_int_ms(msg_time)
                        msg_sender = getattr(msg, 'sender', None) or getattr(msg, 'sender_id', None)
                        
                        # Получаем chat_id из сообщения, если есть, иначе используем переданный
                        msg_chat_id = getattr(msg, 'chat_id', None)
                        if msg_chat_id is None:
                            msg_chat_id = chat_id
                        # Всегда гарантируем, что chat_id не None
                        if msg_chat_id is None:
                            print(f"⚠️ Message {idx} has no chat_id and none provided, skipping")
                            continue
                        
                        msg_dict = {
                            "id": str(msg_id),  # Всегда строка для совместимости
                            "chat_id": msg_chat_id,  # Всегда число, не None
                            "text": msg_text,
                            "sender_id": msg_sender,
                            "date": msg_time_ms,  # Swift ожидает Int?
                            "time": msg_time_ms,  # Внутренняя сортировка/отладка
                            "type": msg.type.value if hasattr(msg.type, 'value') else str(msg.type) if hasattr(msg, 'type') else None,
                        }
                        messages_list.append(msg_dict)
                        print(f"  Message {idx}: id={msg_id}, text={msg_text[:30]}, time={msg_time}")
                    except Exception as e:
                        print(f"⚠️ Error processing message {idx}: {e}")
                        import traceback
                        traceback.print_exc()
                        continue
                
                # Сортируем по времени (старые первыми, новые последними)
                messages_list.sort(key=lambda x: x.get("time", 0) or 0)
                
                # Добавляем отладочную информацию
                print(f"✓ Processed {len(messages_list)} messages for chat_id={chat_id}")
                if messages_list:
                    print(f"  First message: id={messages_list[0].get('id')}, text={messages_list[0].get('text', '')[:50]}")
                    print(f"  Last message: id={messages_list[-1].get('id')}, text={messages_list[-1].get('text', '')[:50]}")
                else:
                    print(f"  ⚠️ No messages to return")
                
                return {"success": True, "messages": messages_list}
            
            return self._run_async(_get_messages())
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
                # Подключаемся к Socket
                await self.client.connect(self.client.user_agent)
                
                # Если есть сохраненный токен, используем его для синхронизации
                if self.client._token:
                    # Синхронизируем состояние с сервером
                    await self.client._sync(self.client.user_agent)
                    await self.client._post_login_tasks(sync=False)
                    
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
                await self.client.close()
                return {"success": True, "message": "Client stopped"}
            
            return self._run_async(_stop())
        except Exception as e:
            return {"success": False, "error": str(e)}


# Глобальный экземпляр для использования из Swift
_wrapper_instance: Optional[MaxClientWrapper] = None


def create_wrapper(phone: str, work_dir: Optional[str] = None, token: Optional[str] = None) -> str:
    """Создать глобальный экземпляр обертки."""
    global _wrapper_instance
    if not PYMAX_AVAILABLE:
        return json.dumps({"success": False, "error": "pymax not available - missing dependencies"})
    try:
        _wrapper_instance = MaxClientWrapper(phone, work_dir, token)
        return json.dumps({"success": True})
    except RuntimeError as e:
        if "pymax not available" in str(e):
            return json.dumps({"success": False, "error": "pymax not available - missing dependencies"})
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
