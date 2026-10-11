# Патчи

| Патч | Платформа | Что меняет | Как применяется |
|------|-----------|------------|-----------------|
| `bufferfix` | Linux | `bin/engine_{amd,i486,i686}.so`, `cstrike/bin/server_i486.so` | ELF-перезапись, `patches/patch-srcds-bufferfix.py` |
| `steamclient` | Linux | `bin/steamclient_i486.so` | байтовый патч, тот же скрипт |
| `healthfix` | Linux + Windows | память `server` / `engine` во время работы | SM-плагин `HealthLimitFix` + gamedata |
| `--valve-rc` | обе | `cstrike/cfg/valve.rc` | замена файла (`configs/`) |

Оригиналы сохраняются рядом: `*.so.orig`, `valve.rc.orig`, `server.cfg.orig`.
Повторный запуск установщика видит уже пропатченные файлы и ничего не ломает.

## bufferfix (зависания)

Движок и `server_i486.so` вызывают `memcpy` на перекрывающихся буферах. Старая glibc
это прощала, новая (Debian 9+) — нет: сервер виснет, спамит `Unknown command ":"`,
криво читает cfg, пишет `Incorrect price blob version!`.

Скрипт перенаправляет все релокации `memcpy` на `memmove` и обнуляет запись `memcpy` в
`.dynsym` / `.gnu.version`. Это те же правки, что в `srcds_patch` (bruno_args, hlmod),
только без готовых бинарей в git. Подробно:
[sourcemod-css34/testing/docs/bufferfix.md](https://github.com/fmu1337/sourcemod-css34/blob/master/testing/docs/bufferfix.md).

На Windows не нужен (это проблема glibc).

## steamclient

Три места в `steamclient_i486.so`, которые пишут `Assertion Failed: !"Implement me!"`,
заменяются на `jmp +0x0a` + NOP. Только убирает шум в консоли.

## healthfix (HealthLimitFix, Reg1oxeN)

В CS:S v34 `m_iHealth` у `DT_BasePlayer` передаётся клиенту 10 битами, поэтому HP выше
1023 клиент видит неправильно. Плагин при загрузке:

1. находит `SendProp` `m_iHealth` через `ServerClassInit<DT_BasePlayer>` и ставит
   `m_nBits = 17`;
2. меняет CRC таблиц (`g_SendTableCRC = 1337`) и держит `sv_sendtables 1`, чтобы клиент
   взял таблицы с сервера, а не свои локальные.

Файлы: `patches/healthfix/` (`.smx`, исходник `.sp`, gamedata `health-patch.txt` с
сигнатурами для Linux и Windows). Нужен SourceMod. Установщик кладёт их в
`addons/sourcemod/` и добавляет `sv_sendtables 1` в `server.cfg`.

## valve.rc

- `debian9` — стоковый вариант со `stuffcmds` (по умолчанию вместе с `bufferfix`);
- `minimal` — без `stuffcmds` (обходит баг буфера, если `bufferfix` не применён);
- `stock` — не трогать.
