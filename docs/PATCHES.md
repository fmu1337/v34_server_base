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

Архив `status_protect` — три пропатченных `engine_*.so` + плагин `status_protect.smx`.
Разбор отличий от стоковых engine:

| Правка | Что было | Здесь |
|--------|----------|-------|
| `CSteam3::OnGSClientDenyHelper`: в таблице переходов `switch (EDenyReason)` ветки NoLicense (4), SteamConnectionLost (11), SteamConnectionError (12), SteamValidationStalled (14) ведут на `ret` | клиента кикало «No Steam logon», «does not own this game» и т.п. | `steamdeny` |
| `CBaseServer::ConnectClient`: `je` на отказ «LAN servers are restricted to local clients (class C)» заменён на NOP | при `sv_lan 1` пускает только локальную сеть | `lanfix` |
| строки команд `ping` → `ghor`, `status` → `dbause` | клиент не может вызвать движковые `status`/`ping`, их подменяет плагин | не перенесено |

`srcds_patch.py --only steamdeny,lanfix` на стоковых engine даёт байт в байт файлы из
архива, кроме переименования команд.

Переименование команд не переносил: `status`/`ping` от клиента закрывает ProtectCMDS
(ниже), без правки бинарей и без поломки `status` для rcon/HLSW. `RegConsoleCmd("status")`
в SourceMod клиентскую команду не ловит: движок выполняет `status`/`ping` сам, в
`ClientCommand` игры они не доходят.

`steamdeny` и `lanfix` выключены по умолчанию: с эмулятором eSTEAMATiON из сборки
сервера Steam-отказы обычно не приходят, а `lanfix` нужен только серверам с `sv_lan 1`.

## valve.rc

- `debian9` — `stuffcmds` без `exec default.cfg` (по умолчанию вместе с `bufferfix`);
- `minimal` — без `stuffcmds` (обходит баг буфера, если `bufferfix` не применён);
- `stock` — не трогать.

## ProtectCMDS — `--plugins protectcmds`

SM-расширение `protectcmds.ext.so` (только Linux). Главное для нас — детур
`CGameClient::ExecuteStringCommand`: через него проходит **каждая** команда клиента,
в том числе движковые `status`/`ping`, до того как движок их выполнит. Там:

- кик за флуд командами (больше `blockcmds_maxcommands` = 30 в секунду);
- ~60 встроенных запрещённых команд css34 (`changelevel`, `dump_*`, `npc_*`, …) и свой
  список в `data/protectcmds/blockcmds.txt`;
- forward `ProtectCMDS_OnClientCommand(client, command)`.

Плагин `protectcmds_status.smx` (исходник `extras/protectcmds/protectcmds_status.sp`) через
этот forward отправляет клиентские `status`/`ping` в `sm_status`/`sm_ping` из
`smac_status` (антиспам, показ только себя/админам), а движковые версии не выполняются.
Без SMAC обе команды для игроков просто закрыты. Из консоли сервера и по rcon `status`
работает как обычно.

Остальное, что включено в `protectcmds.ini`: фильтр пакетов (FilterPacket), GamePacketFix,
хеширование SteamID, GameStats, VACPatch и набор встроенных фиксов (имена, spec_goto,
observer loop, SourceTV, урон и т.п.). `OSFix` (тот же memcpy → memmove, но в рантайме)
установщик выключает, если применён `bufferfix`. Встроенный апдейтер выключен: он качает
бинарь со стороннего сайта.

Что ProtectCMDS **не** делает: детур `CBaseServer::ConnectClient` у него только для forward
`ProtectCMDS_OnClientPreConnect` (плагины могут отклонить игрока), проверку «LAN servers are
restricted» он не убирает; `CSteam3::OnGSClientDenyHelper` не трогает. Поэтому `steamdeny` и
`lanfix` остаются отдельными бинарными патчами, а от status/ping protect больше ничего не нужно.

Бинарь собирает `.github/workflows/protectcmds.yml` (скрипт `extras/protectcmds/build.sh`) из
`fmu1337/ProtectCMDS@bbdc766` (форк WeSTManCoder/ProtectCMDS, сейчас без отличий;
`ENGINE=css34`, MM 1.10, hl2sdk-episode1) в `debian:11` — так он грузится на старых glibc — и
кладёт в релиз `protectcmds-bbdc766` этого репозитория. Вариантов два, потому что SourceMod
1.13 поднял версию API расширений:

| Файл | SDK | Для SourceMod |
|------|-----|---------------|
| `protectcmds-api7.ext.so` | SM 1.6 | 1.11, 1.12 (принимают API ≤ 8) |
| `protectcmds-api9.ext.so` | SM 1.13.0.7394 (API 9) | 1.13 (7394 принимает только 9, 7472 — 9…11) |

Установщик выбирает вариант по версии в `addons/sourcemod/bin/sourcemod.logic.so` и ставит его
как `extensions/protectcmds.ext.so`.
