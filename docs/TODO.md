# TODO

## Windows

Отложено, сейчас установщик только для Linux. Заготовка лежит в `todo/windows/`:
`install.ps1` ставит сервер, Metamod/SourceMod и SMAC (с компиляцией), пишет `server.cfg` и `start-server.bat`. Из CI убран.

Что известно:

- **Файлы сервера:** `srcds_css34_4044.zip` + `srcds_css34_w_a.zip` +
  `srcds_css34_w_eSTEAMATiON.RC9.U1.zip` (эмулятор Steam, RC9 Update 1 — та же версия, что в
  Linux-сборке). `RC3.WWII` — старее (май 2010), отличается только эмулятором/конфигом и
  приложенным патчером `ugsp64.exe`; Valve-файлы в обоих архивах одинаковые.
  `srcds_css34_w_a.zip` несёт свой `cstrike/addons`, установщик его вычищает.
- **Не работает:** на `windows-latest` раннере `srcds.exe` останавливается после строки
  `Network: IP …` и не грузит карту (TCP-порт RCON принимает соединения, но сервер не
  активен). Пробовали: отдельная консоль (без неё — спам `CTextConsoleWin32::GetLine`),
  аргументы как в нативном smoke `sourcemod-css34`, `+sv_lan 1`, `-ip 127.0.0.1`, эмулятор
  RC9.U1 — не помогло. Нужна проверка на живой Windows-машине (нет ли окна/диалога при
  старте).
- **Манифест:** `install.ps1` берёт файлы сервера из `server.mirror_release` (наш релиз
  `server-css34-4044`, там же Windows-архивы) и первый закреплённый тег линии SM. Указатели
  `line-<линия>` в sourcemod-css34 — только Linux, sha256 в `install.ps1` не проверяется.
- **Metamod/SourceMod:** наши Windows-пакеты для `sm12-latest`, `sm13-*`; у
  `sm13-mm20-khook` Windows-сборка падает (см. sourcemod-css34). У rom4s нет Windows-сборки
  Metamod — берётся наш MM 1.10.7 (`1.11.0.6572-mm1.10.7`). myarena — только Linux.
- **Патчи:** `bufferfix` на Windows не нужен (проблема glibc).
- **steamdeny/lanfix для `engine.dll`:** `css_v34_engine_fix.zip` (GoDtm666) содержит
  пропатченный `engine.dll` — те же правки, что на Linux: таблица переходов
  `OnGSClientDenyHelper` (записи 4/11/12/14 → `ret 0Ch`), `jne`→`jmp` перед отказом
  «LAN servers are restricted…» (смещение `0xC6E7` в стоковом `w_a`), переименование
  `status`/`ping`. Готовый файл ставить нельзя: он сделан из `engine.dll` из `w_a.zip`, а
  эмулятор RC9.U1 кладёт свой `engine.dll` (другой CRC). Нужен патч по шаблону байтов
  (Python или порт на PowerShell).
- **ProtectCMDS:** Windows-сборки нет (Makefile только под Linux).
- **Smoke:** `lib/smoke.py` уже умеет `srcds.exe` (отдельная консоль, `+sv_lan 1`).
