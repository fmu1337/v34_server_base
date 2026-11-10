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
| `hidecmds` | нет | `engine_*.so` | клиент не может выполнить `status` / `ping` (консоль и rcon — могут) |
| `logonmsg` | нет | `engine_*.so` | глушит `Could not establish connection to Steam servers.` |
| `staticprop` | нет | `engine_*.so` | глушит `SOLID_VPHYSICS static prop with no vphysics model!` |
| `botbuyzone` | нет | `cstrike/bin/server_i486.so` | глушит `<team> bot spawned outside of a buy zone` |
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
| строки команд `ping` → `ghor`/`enrs`, `status` → `dbause`/`debuus` | `hidecmds` (иначе) |

`srcds_patch.py --only steamdeny,lanfix` на стоковых Linux-engine даёт байт в байт файлы из
архивов, кроме переименования команд. Оба патча — только Linux, по умолчанию выключены.
Windows-эквивалент (`engine.dll`) описан в [TODO.md](TODO.md).

Переименование там — замена байтов строк `"status"` / `"ping"`. Строка у команды одна: на неё
указывают имя `ConCommand` (статический конструктор в `host_cmd`), белый список `s_clcommands`
(см. `hidecmds` ниже) и, для `status`, `CHLTVClient::ExecuteStringCommand`. Поэтому команда
переименовывается целиком: в консоли, rcon и у клиента есть только `dbause` / `ghor`, а
`status` / `ping` — «Unknown command» (или их перехватывает плагин, например `dsp_status`).
`status` своей строки не имеет — это хвост подсказки `net_status`, отсюда «Shows current
network dbause». `hidecmds` возвращает имена и закрывает команды только для клиентов. Без патча клиентские `status`/`ping` перехватывает ProtectCMDS
([PROTECTCMDS.md](PROTECTCMDS.md)); `RegConsoleCmd("status")` в SourceMod без патча клиентскую
команду **не** ловит: движок выполняет `status`/`ping` сам, до `ClientCommand` игры.

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

## hidecmds — `status` / `ping` только для консоли

Строка команды от клиента попадает в `CGameClient::ExecuteStringCommand`. Он берёт первое слово
и ищет его в `s_clcommands` — NULL-терминированном массиве указателей на строки:

```
status, pause, setpause, unpause, ping, NULL
```

Нашлось — `Cmd_ExecuteString(s, src_client)`, команду выполняет движок (`Host_Status_f` /
`Host_Ping_f` в ветке `cmd_source == src_client` печатают ответ клиенту). Не нашлось — строка
идёт в `g_pServerPluginHandler->ClientCommand` → `ClientCommand` игры, как любая игровая
команда.

Патч сдвигает оставшиеся записи к началу массива, освободившиеся слоты повторяют последнюю:

```
pause, setpause, unpause, unpause, unpause, NULL
```

Укоротить список (`NULL` раньше) нельзя: каждый слот — релокация `R_386_RELATIVE`, и glibc
прибавляет базу библиотеки к первым `DT_RELCOUNT` релокациям, не глядя на их тип, так что `0` с
`R_386_NONE` превратился бы в адрес базы. Первая версия патча так и делала — повторный запуск
это исправляет (`repaired … slot(s)`). Код движка не меняется.

Что получается:

- клиентский `status` / `ping` до движка не доходит: без плагинов игра ответит «Unknown
  command», а SourceMod может повесить на них `RegConsoleCmd` / `AddCommandListener`;
- консоль сервера, `rcon status`, HLSW, `lib/smoke.py` — без изменений (`src_command`, список
  не проверяется);
- `pause` / `setpause` / `unpause` остаются клиентскими, как в стоке;
- на engine от GoDtm666 строки `dbause`/`debuus` → `status`, `ghor`/`enrs` → `ping`
  возвращаются обратно (это имена самих команд), после чего записи убираются из списка: в
  консоли и rcon снова настоящие `status` / `ping`, клиентам они недоступны.

Отличие от переименования: в GoDtm666 команда переименована для всех — консоль и rcon тоже
получают настоящий `status` только через `dbause`, а клиент, узнавший имя, тоже может его
вызвать; здесь консоль работает как в стоке, а клиенту команда недоступна. Отличие от ProtectCMDS:
ProtectCMDS решает по каждому клиенту и может отдать `sm_status`; `hidecmds` закрывает команду
на уровне движка, даже если плагины не загрузились. Вместе не мешают.

Как сделано (`patch_hidecmds`): массив по символу `s_clcommands`, релокации — из `.rel.dyn`.
Если в списке нет ни одного имени из `HIDDEN_CLCOMMANDS` — `already`.

## logonmsg, staticprop, botbuyzone — шум в консоли

Перенесены из пропатченных engine/server в сборке с eSTEAMATiON RC8 (`engine_i486.so` после
patchelf, `server_i486.so`). На стоковых файлах патч даёт те же байты, кроме мёртвых байтов
после перехода. Поведение сервера не меняют — только убирают сообщения.

### logonmsg — `CSteam3::OnLogonFailure`

```
if (this->[0xf6] && !this->[0xf3]) {
    if (pLogonFailure->eResult == 20 /* ServiceUnavailable */) {
        if (!sv_lan) Msg("Connection to Steam servers successful (SU).\n");
    } else if (!sv_lan)
        Msg("Could not establish connection to Steam servers.\n");      <- jne → jmp
    this->[0xf3] = 1; this->[0xf1] = 1;
}
```

`jne` через первый `Msg` → `jmp`. Флаги ставятся как раньше (поля по смещениям, имена не
восстановлены): обработка неудачного входа та же, пропадает только сообщение. Сервер v34 к Steam никогда не подключится (CSER мёртв), так что сообщение —
просто шум на каждом старте.

### staticprop — `CStaticProp::InsertPropIntoKDTree`

Статический проп с `SOLID_VPHYSICS`, у модели которого нет коллизии: движок пишет
`SOLID_VPHYSICS static prop with no vphysics model! (<модель>)`, ставит пропу `SOLID_NONE` и
выходит. Короткий `jmp` в начале блока перепрыгивает `Q_strncpy` + `Warning` на
`m_nSolidType = SOLID_NONE`. На кастомных картах таких сообщений бывают сотни.

В amd-сборке аргументы передаются `push`-ами, поэтому переход ведёт на инструкцию после
`add esp, 10h` — стек сбалансирован.

### botbuyzone — `BuyState::OnUpdate` (server_i486.so)

Бот заспавнился вне зоны закупки:

```
m_doneBuying = true;
if (IsEFlagSet(EFL_DIRTY_ABSTRANSFORM)) CalcAbsolutePosition();   <- jne
CONSOLE_ECHO("%s bot spawned outside of a buy zone (%d, %d, %d)\n", team, x, y, z);
return;
```

`jne rel32` → `jmp` на `return` (тот же, что после `CONSOLE_ECHO`) + `nop`. Бот так же не
покупает; не выводится только сообщение (и не пересчитывается позиция, нужная только для него).
Сообщение появляется на картах без buy-зон (aim_, awp_, fy_, deathmatch) на каждом респавне
каждого бота.

## valve.rc

- `debian9` — `stuffcmds` без `exec default.cfg` (по умолчанию вместе с `bufferfix`);
- `minimal` — без `stuffcmds` (обходит баг буфера, если `bufferfix` не применён);
- `stock` — не трогать.

## ProtectCMDS — `--plugins protectcmds`

Не патч бинарей, а SM-расширение; всё про него — в [PROTECTCMDS.md](PROTECTCMDS.md).
