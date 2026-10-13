# Патчи

Все бинарные патчи делает `patches/srcds_patch.py` (Linux, ELF32). Каждый патч сначала
проверяет исходные байты и узнаёт собственный результат: повторный запуск пишет
`already` и ничего не трогает. Оригиналы лежат рядом: `*.so.orig`; для cfg —
`valve.rc.orig`, `server.cfg.orig`.

| Патч | По умолчанию | Файлы | Что делает |
|------|:-:|-------|------------|
| `bufferfix` | да | `bin/engine_{amd,i486,i686}.so`, `cstrike/bin/server_i486.so` | `memcpy` → `memmove` (зависания) |
| `steamclient` | да | `bin/steamclient_i486.so` | глушит `Assertion Failed: !"Implement me!"` |
| `steamdeny` | нет | `engine_*.so` | не кикать по Steam-отказам (из патча GoDtm666) |
| `lanfix` | нет | `engine_*.so` | пускать интернет-клиентов при `sv_lan 1` (оттуда же) |
| `--valve-rc` | `auto` | `cstrike/cfg/valve.rc` | замена файла (`configs/`) |

Windows пока отложен — см. [TODO.md](TODO.md).

## bufferfix (зависания)

Движок и `server_i486.so` вызывают `memcpy` на перекрывающихся буферах. Старая glibc
это прощала, новая (Debian 9+) — нет: сервер виснет, спамит `Unknown command ":"`,
криво читает cfg, пишет `Incorrect price blob version!`.

Все релокации `memcpy` перенаправляются на `memmove`, запись `memcpy` в `.dynsym` /
`.gnu.version` обнуляется. Те же правки, что в `srcds_patch` (bruno_args, hlmod), только
без готовых бинарей в git. Подробно:
[sourcemod-css34/testing/docs/bufferfix.md](https://github.com/fmu1337/sourcemod-css34/blob/master/testing/docs/bufferfix.md).

## steamclient

Три места в `steamclient_i486.so`, которые пишут `Assertion Failed: !"Implement me!"`,
заменяются на `jmp +0x0a` + NOP. Только убирает шум в консоли.

## steamdeny и lanfix (из status/ping protect, GoDtm666, myarena 2012)

Источник: архивы `status_protect` и `css_v34_engine_fix` — пропатченные `engine_{i486,i686,amd}.so`
(и в `css_v34_engine_fix` ещё `engine.dll`) + плагин `status_protect.smx` (SM 1.4). Отличия от
стоковых engine из `srcds_css34_l_a.zip` / `srcds_css34_w_a.zip`:

| Правка | Здесь |
|--------|-------|
| `CSteam3::OnGSClientDenyHelper`: 4 записи таблицы переходов → выход из функции | `steamdeny` |
| `CBaseServer::ConnectClient`: отказ «LAN servers are restricted…» отключён | `lanfix` |
| строки команд `ping` → `ghor`/`enrs`, `status` → `dbause`/`debuus` | не перенесено (ProtectCMDS) |

`srcds_patch.py --only steamdeny,lanfix` на стоковых Linux-engine даёт байт в байт файлы из
архивов, кроме переименования команд. Оба патча — только Linux, по умолчанию выключены.
Windows-эквивалент (`engine.dll`) описан в [TODO.md](TODO.md).

Переименование команд не нужно: клиентские `status`/`ping` перехватывает ProtectCMDS
([PROTECTCMDS.md](PROTECTCMDS.md)), а `status` из консоли сервера / rcon / HLSW продолжает
работать. `RegConsoleCmd("status")` в SourceMod клиентскую команду **не** ловит: движок
выполняет `status`/`ping` сам, до `ClientCommand` игры.

### steamdeny — `CSteam3::OnGSClientDenyHelper(CBaseClient*, EDenyReason, const char*)`

Обработчик отказа Steam: steamclient (у нас — эмулятор eSTEAMATiON) сообщает «отказать этому
клиенту» с причиной `EDenyReason`. Внутри — `cmp eax, 0Eh; ja default; jmp [table + eax*4]`,
15 веток; ветка либо выходит молча, либо кикает клиента (`Disconnect` через vtable `+0x38`).
Часть веток смотрит на `sv_lan` (релокация `R_386_32` на символ `sv_lan`, поле `+0x2c` —
`m_nValue`).

Сток (`engine_i486.so` из `srcds_css34_l_a.zip`):

| # | EDenyReason | `sv_lan 0` | `sv_lan 1` |
|---|-------------|------------|------------|
| 0, 2 | Invalid, Generic | кик «Client dropped by server» | то же |
| 1 | InvalidVersion | кик «Client version incompatible…» | то же |
| 3 | NotLoggedOn | кик «No Steam logon» | молча |
| **4** | **NoLicense** | кик «This Steam account does not own this game» | **кик** |
| 5 | Cheater | кик «VAC banned from secure server» | молча |
| 6 | LoggedInElseWhere | кик «…being used in another location» | молча |
| 7 | UnknownText | кик с переданным текстом | то же |
| 8 | IncompatibleAnticheat | кик «external tool… incompatible…» | то же |
| 9 | MemoryCorruption | кик «Memory corruption detected» | то же |
| 10 | IncompatibleSoftware | кик «software… not compatible with Secure servers» | то же |
| **11** | **SteamConnectionLost** | кик «No Steam logon» | молча |
| **12** | **SteamConnectionError** | кик «No Steam logon» | молча |
| 13 | SteamResponseTimedOut | кик «Client timed out» | то же |
| **14** | **SteamValidationStalled** | кик «Error verifying STEAM UserID Ticket» | пишет в клиента `+0x60 = 1`, `+0x64 = 0`, `+0x68 = 0` и выходит |

Патч: записи **4, 11, 12, 14** таблицы указывают на выход из функции — `add esp,0Ch; ret` в
i486/i686, `ret` в amd (`ret 0Ch` в Windows `engine.dll`). Код не меняется, только четыре
4-байтовых адреса в `.rodata`.

Что получается:

- **NoLicense** не кикает никогда — единственное, что меняется и при `sv_lan 1`;
- **SteamConnectionLost / SteamConnectionError / SteamValidationStalled** не кикают и при
  `sv_lan 0` (при `sv_lan 1` движок их и так игнорирует);
- побочный эффект для 14 при `sv_lan 1`: стоковая ветка перед выходом пишет три поля клиента
  (похоже на LAN-SteamID / флаг валидации — не проверено), с патчем — просто выход;
- не тронуты NotLoggedOn (3), Cheater (5), LoggedInElseWhere (6) и остальные — при `sv_lan 0`
  они кикают как раньше.

Зачем: сервер с `sv_lan 0`, у которого Steam-бэкенд v34 (CSER `steambeta1:27013`) давно мёртв
или эмулятор шлёт отказ — игроков кикает «No Steam logon», «Error verifying STEAM UserID
Ticket», «does not own this game». С eSTEAMATiON такие отказы обычно не доходят, патч —
страховка; в живой игре не проверялся.

Как сделано (`patch_steamdeny`): функция по символу
`_ZN7CSteam320OnGSClientDenyHelperEP11CBaseClient11EDenyReasonPKc`; проверяются
`cmp eax, 0Eh` и `jmp [таблица + eax*4]` в начале; адрес выхода — первый `ret` (вместе с
`add esp,0Ch` перед ним, если есть); старые записи 4/11/12/14 должны указывать внутрь функции.
Повторный запуск — `already`.

### lanfix — `CBaseServer::ConnectClient(...)`

При подключении `ConnectClient` вызывает виртуальную `CBaseServer::CheckIPRestrictions(adr,
authProtocol)` (слот vtable `+0xC0`):

- loopback → можно;
- `sv_lan 0` → можно;
- `sv_lan 1` → можно, только если адрес локальный (LAN / зарезервированные подсети).

Если `false` — `je` на `RejectConnection("LAN servers are restricted to local clients (class
C).\n")`.

Патч: этот `je` (`0F 84 rel32`, 6 байт) → `66 89 C0 66 89 C0` (2× `mov ax, ax` = NOP), результат
проверки игнорируется. В `engine_i486.so` — смещение `0x178020`; в Windows `engine.dll` то же
сделано `jne` → `jmp` по `0xC6E7`.

Итог: при `sv_lan 1` пускаются клиенты из интернета; при `sv_lan 0` ничего не меняется
(проверка и так `true`).

Зачем держать `sv_lan 1` на интернет-сервере: в LAN-режиме сервер не шлёт heartbeat на
мастер-серверы и не валидирует Steam-тикеты — весь набор Steam-отказов из таблицы выше
пропадает. Старый способ гарантированно избавиться от Steam-киков.

Риски (проверить до включения):

- при `sv_lan 1` движок может выдавать клиентам `STEAM_ID_LAN` → баны/админы по SteamID
  ломаются (все один «LAN»). Даёт ли eSTEAMATiON нормальные ID в LAN-режиме — не проверено;
- сервер не попадает в списки Steam (для v34 с `-nomaster` неважно);
- пропадает единственная встроенная защита «только LAN»; остаются `banip` и FilterPacket
  ProtectCMDS.

ProtectCMDS это не заменяет: его детур `ConnectClient` только вызывает
`ProtectCMDS_OnClientPreConnect` (плагины могут отклонить игрока), `CheckIPRestrictions` он не
трогает.

Как сделано (`patch_lanfix`): функция по символу
`_ZN11CBaseServer13ConnectClientER8netadr_siiiPKcS3_S3_iS3_i`; в ней ищется адрес строки
отказа, затем `je rel32`, ведущий на блок, который эту строку загружает. Повторный запуск —
`already`.

Рекомендация: `steamdeny` — для `sv_lan 0`; `lanfix` — только если сервер сознательно в
`sv_lan 1`, и тогда обязательно проверить SteamID с eSTEAMATiON.

## valve.rc

- `debian9` — `stuffcmds` без `exec default.cfg` (по умолчанию вместе с `bufferfix`);
- `minimal` — без `stuffcmds` (обходит баг буфера, если `bufferfix` не применён);
- `stock` — не трогать.

## ProtectCMDS — `--plugins protectcmds`

Не патч бинарей, а SM-расширение; всё про него — в [PROTECTCMDS.md](PROTECTCMDS.md).
