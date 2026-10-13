# ProtectCMDS

SM-расширение `protectcmds.ext.so` (WeSTManCoder, наш форк
[`fmu1337/ProtectCMDS`](https://github.com/fmu1337/ProtectCMDS)), только Linux.
Установщик: `--plugins protectcmds` (по умолчанию вместе с SMAC).

## Что оно делает

Главное — детур `CGameClient::ExecuteStringCommand`: через него проходит **каждая** команда
клиента, в том числе движковые `status`/`ping`, до того как движок их выполнит.

- кик за флуд командами (больше `blockcmds_maxcommands` = 30 в секунду);
- ~60 встроенных запрещённых команд css34 (`changelevel`, `dump_*`, `npc_*`, `cl_fullupdate`, …)
  и свой список `data/protectcmds/blockcmds.txt` (`[args]`, `[sensitive]`);
- forward `ProtectCMDS_OnClientCommand(int client, const char[] command)`.

Плагин `protectcmds_status.smx` (`extras/protectcmds/protectcmds_status.sp`) через этот forward
отправляет клиентские `status`/`ping` в `sm_status`/`sm_ping` из `smac_status` (антиспам,
показ только себя/админам); движковые версии не выполняются. Без SMAC обе команды для игроков
закрыты. Из консоли сервера и по rcon `status` работает как обычно.

Модули из `protectcmds.ini`:

| Секция | Что |
|--------|-----|
| `BlockCmds` | детур `ExecuteStringCommand`, флуд/блок-лист, forward выше |
| `FilterPacket` | `ProcessConnectionlessPacket` / `CNetChan::ProcessPacket` / IP-фильтр: кривые и флуд-пакеты |
| `GamePacketFix` | `CNetChan::ProcessMessages`: битые игровые пакеты от клиентов |
| `SteamIDHashing` | хеш SteamID с солью из `steamid_hash.txt` |
| `GameStats` | `CUploadGameStats::UpdateConnection` |
| `VACPatch` | значок VAC (`SteamGameServer` → `BSecure` = 1, если нет `-insecure`) |
| `OSFix` | рантайм-детур `memcpy` → `memmove` — **дубль `bufferfix`**, установщик выключает при `bufferfix` |
| `Updater` | качает бинарь с `http://protectcmds.gm-world.ru` — **выключаем** |

Без настроек в ini всегда включены: block load plugin, `Studio_BoneIndexByName`, GameUI,
observer loop, SourceTV, `TakeDamage`, `FireGameEvent`, имена, voxel hash, `spec_goto`,
voice + forward-ы `ProtectCMDS_OnClientPreConnect(Post)` (детур `CBaseServer::ConnectClient`) и
`OnClientVoice`.

Чего ProtectCMDS **не** делает: проверку «LAN servers are restricted» в `ConnectClient` не
убирает, `CSteam3::OnGSClientDenyHelper` не трогает — для этого бинарные патчи `lanfix` и
`steamdeny` ([PATCHES.md](PATCHES.md)).

## Готовый архив `ProtectCMDS_1.0.10_1.zip`

```
cstrike/addons/sourcemod/extensions/protectcmds.ext.so   581704 байт
cstrike/addons/sourcemod/extensions/protectcmds.autoload
cstrike/addons/sourcemod/scripting/include/protectcmds.inc
cstrike/addons/sourcemod/data/protectcmds/protectcmds.ini
cstrike/addons/sourcemod/data/protectcmds/blockcmds.txt
cstrike/addons/sourcemod/data/protectcmds/steamid_hash.txt
```

- бинарь: версия `1.0.10`, `ProtectCMDS [CS:S v34]`, собран gcc 4.9.4 (Ubuntu 14.04), требует
  glibc ≤ 2.15 — грузится на любых живых дистрибутивах;
- `GetExtensionVersion()` возвращает **7** (`mov eax, 7; ret`) — SDK SM 1.6: грузится на SM
  1.11/1.12, **не** грузится на SM 1.13 (нужно ≥ 9);
- `protectcmds.ini`: всё включено, `osfix_enable=0`, **апдейтер включён** (`=1`) — у нас
  выключаем;
- `blockcmds.txt`: блокирует `sm [args]` и `meta [args]` (игроки не видят список плагинов/версии);
  примеры `status [args]` / `ping [args]` закомментированы;
- `protectcmds.inc`: описаны `ProtectCMDS_OnClientPreConnect(Post)`, `OnClientVoice`,
  `ProtectCMDS_GetAbsoluteFrameTime`; **нет** `ProtectCMDS_OnClientCommand` (в бинаре он есть);
- `steamid_hash.txt` — соль для `SteamIDHashing` (своя на каждый сервер; общую из архива лучше
  заменить).

Наш `protectcmds-api7` из исходников (`bbdc766`) функционально то же, но собран на debian:11
(glibc ≤ 2.32). Для SM ≤ 1.12 можно брать бинарь из архива как есть.

## Что поправить в форке `fmu1337/ProtectCMDS`

1. **Сборка.** Makefile с захардкоженными путями (`/home/src_sdk/...`); с `-Werror` на новом gcc
   падает (`register` в hl2sdk, `-Wstringop-truncation`); на C++17 `clamp()` hl2sdk конфликтует с
   `std::clamp`. Нужно: пути SDK через переменные, `-std=gnu++14`, без `-Werror`, CI-сборка на
   старой glibc. Сейчас это делает `extras/protectcmds/build.sh` через `sed`.
2. **SDK SourceMod.** Собрано с SDK 1.6 → API 7. SM 1.11/1.12 принимают API ≤ 8, SM 1.13 — ≥ 9
   (1.13.0.7394 — только 9, 7472 — 9…11). Для 1.13: `sdk/smsdk_ext.{cpp,h}` из SM 1.13, пути
   `sourcepawn/include` и `public/amtl`, для `ENGINE_CSS34` явный `#include <eiface.h>` (новый
   `smsdk_ext.h` его не подтягивает). API 9 — это переделка SourcePawn API, поэтому подменить
   число в `GetExtensionVersion()` нельзя, нужна честная сборка.
3. **Конфиги в репо нет.** Без `data/protectcmds/protectcmds.ini` расширение выключено
   (`protectcmds_enable` по умолчанию 0). Положить `protectcmds.ini` (апдейтер и OSFix выключены),
   `blockcmds.txt`, пример `steamid_hash.txt`.
4. **Апдейтер.** HTTP без TLS, сторонний сервер, подменяет бинарь. Выключить по умолчанию или
   удалить модуль.
5. **`.inc`.** Добавить `ProtectCMDS_OnClientCommand` (есть в бинаре, нет в `.inc`), версию
   (`ProtectCMDS_GetVersion` закомментирован).
6. **Мелочи.** `blockcmds_maxcommands` читается из `[blockCmds]`, включение — из `[BlockCmds]`
   (работает только из-за регистронезависимого INIReader); `strcpy` в буфер 1024 после проверки
   длины; нет Windows-сборки.
7. **Metamod.** Собрано против MM 1.10 `core-legacy`; в нашем CI грузится и с MM 1.10 (rom4s), и
   с MM 1.12 (SM 1.12/1.13). Закрепить тестом.

## Как отдавать разные сборки

| Вариант | Как | Плюсы | Минусы |
|---------|-----|-------|--------|
| A. Несколько ассетов + манифест (сейчас) | `protectcmds-api7.ext.so`, `protectcmds-api9-sm7394.ext.so` в релизе, установщик выбирает | просто | выбирает установщик (по версии из `sourcemod.logic.so`) |
| B. Один архив, обе сборки | установщик копирует нужную в `protectcmds.ext.so` | одна загрузка | выбирает всё равно установщик |
| **C. Тонкий загрузчик** (выбран) | см. ниже | один файл для любого SM | загрузчик — ещё один бинарь |
| D. Один бинарь, отдающий API в рантайме | `GetExtensionVersion()` → 7 или 9 | один файл | два разных ABI SourcePawn в одном коде — хрупко |
| E. Сборка внутри `sourcemod-css34` | расширение в каждом пакете SM | ABI совпадает идеально | только для наших пакетов, rom4s/myarena — по-прежнему A/C |

### C. Тонкий загрузчик — как устроено

```
extensions/protectcmds.ext.so          загрузчик (маленький, без SDK SourceMod)
extensions/protectcmds/api7.so         реальное расширение, SDK SM 1.6   (SM 1.11, 1.12)
extensions/protectcmds/api9.so         реальное расширение, SDK SM 1.13  (SM 1.13)
extensions/protectcmds.autoload
```

SourceMod загружает `protectcmds.ext.so` и вызывает экспорт `GetSMExtAPI()` — это
единственная точка входа расширения. Загрузчик:

1. определяет, какой SM загружен: `dl_iterate_phdr` / `/proc/self/maps` → путь
   `sourcemod.logic.so` → строка версии `1.NN.0.NNNN` в нём (или `dlsym` символа, появившегося в
   1.13);
2. выбирает `api7.so` (SM < 1.13) или `api9.so` (SM ≥ 1.13), путь — рядом с собой (`dladdr` на
   свою функцию);
3. `dlopen(RTLD_NOW | RTLD_LOCAL)` → `dlsym("GetSMExtAPI")` → вызывает и возвращает его
   `IExtensionInterface*` как свой.

Дальше SourceMod говорит напрямую с реальным расширением (версия API, `OnExtensionLoad`, …).
Загрузчик не зависит от SDK SourceMod — только libc/libdl, — поэтому один на все версии.

Тонкости:

- `dlclose` реального `.so` не делать, пока загружен загрузчик (SM выгружает по пути
  загрузчика); проще не выгружать вовсе;
- `myself`/`GetExtensionVersion`/`GetExtensionDateString` отвечает реальное расширение — в
  `sm exts list` будет его имя и версия;
- если версия SM не определилась или нужного `.so` нет — вернуть `nullptr` и написать в stderr
  понятную причину (SM покажет «failed to load»);
- `RTLD_LOCAL`, чтобы символы двух сборок не пересекались (грузится всё равно одна).

Собирать загрузчик и обе реализации — в `fmu1337/ProtectCMDS` (или в `extras/protectcmds/`
здесь), публиковать одним архивом `protectcmds-css34-linux.tar.gz` с деревом `addons/` как выше.
Установщику остаётся распаковать архив — без выбора по версии SM.
