# v34_server_base

Установщик базового сервера **CS:S v34**: файлы сервера, патчи бинарей, Metamod + SourceMod,
доп. плагины. Сейчас только Linux; Windows отложен — см. [docs/TODO.md](docs/TODO.md).

## Быстрый старт

Linux:

```bash
git clone https://github.com/fmu1337/v34_server_base && cd v34_server_base
sudo ./install.sh --deps-only        # 32-bit библиотеки (apt / dnf), один раз
./install.sh                         # интерактивное меню
./install.sh -y --dir /srv/css34     # всё по умолчанию, без вопросов
/srv/css34/start-server.sh
```


## Что ставится

| Шаг | По умолчанию | Варианты |
|-----|--------------|----------|
| Файлы сервера | релиз [`server-css34-4044`](https://github.com/fmu1337/v34_server_base/releases/tag/server-css34-4044) этого репо (копия rom4s, sha256 закреплены в манифесте), при ошибке — bitbucket rom4s | `--server-source auto\|mirror\|rom4s\|skip` |
| Патчи | `bufferfix,steamclient` | + `steamdeny`, `lanfix`, `hidecmds`, `logonmsg`, `staticprop`, `botbuyzone`; `--patch LIST\|all\|none`, `--valve-rc auto\|stock\|debian9\|minimal` |
| Metamod + SourceMod | наш [`sourcemod-css34`](https://github.com/fmu1337/sourcemod-css34), линия `sm13-latest` | `--sm ours\|rom4s\|myarena\|none`, `--sm-line …`, `--metamod default\|legacy` |
| Плагины | SMAC ([`smac_v34`](https://github.com/fmu1337/smac_v34)) + ProtectCMDS ([`fmu1337/ProtectCMDS`](https://github.com/fmu1337/ProtectCMDS), форк WeSTManCoder) | `--plugins smac,protectcmds\|none`, `--smac-mode auto\|compile\|prebuilt` |

Описание патчей — [docs/PATCHES.md](docs/PATCHES.md).

### SourceMod

| `--sm` | Metamod | SourceMod |
|--------|---------|-----------|
| `ours` `sm13-latest` | 1.12.0 (git1229) | 1.13.0.7478 (`-r7`) |
| `ours` `sm12-latest` | 1.12.0 (git1229) | 1.12.0.7257 (`-r6`) |
| `ours` `sm11-oldstable` | 1.12.0 (git1227) + мост для старых плагинов; `--metamod legacy`: 1.10.7 (git976) | 1.11.0.6970, оба ядра (1.ep1 + 2.ep1) |
| `ours` `sm13-mm20` | 2.0.0-dev | 1.13.0.7404 |
| `ours` `sm13-mm20-khook` | 2.0.0-dev (KHook) | 1.13.0.7565 + dhooks |
| `rom4s` | 1.10.6 | 1.11.0.6572 |
| `myarena` | 1.11.0-1130 | 1.11.0.6522 (git6541, fix gamedata 12.10.2020) |

Наши линии ставятся из указателя `line-<линия>` в `sourcemod-css34`: там всегда последняя
сборка линии, прошедшая smoke-тест, под постоянными именами (`sourcemod-css34-linux.tar.gz`,
`mmsource-css34-linux.tar.gz`, у `sm11-oldstable` ещё `mmsource-legacy-css34-linux.tar.gz`). Тег сборки берётся из `lines.json` (по нему ключ кеша), файлы
сверяются по `SHA256SUMS`. Если указателя нет (линию ещё не пересобирали после его появления)
или скачивание не удалось — берутся закреплённые теги из `manifest/sources.json`, по порядку
(их `SHA256SUMS` тоже проверяется, если есть). `--sm-pinned` — только закреплённые теги.

Убраны: `1.13.0.7394` (в пакете нет gamedata SDKHooks для css34 — SMAC пишет «Hook type not
supported»), `1.12.0.7245` (заменён 7253/7257), `sm13-dev`, а также `1.11.0.6970-mm1.10.7`
(падал с SIGABRT при запуске; его заменила линия `sm11-oldstable`).

Закреплённые теги — это те же сборки, что сейчас отдают указатели (`-rN`). Прежние теги без
`-rN` (`1.13.0.7478`/`7472`, `1.12.0.7257`/`7253`, `1.13.0.7404`, `1.13.0.7565`) удалены из
sourcemod-css34 3 ноября 2026 года. Более ранние `-rN` тех же сборок в запасные не взяты: в
них нет `"HintTextPreByte"`, и клиент v34 не показывает `PrintHintText` / `sm_hsay`.

#### SourceMod 1.11 (`sm11-oldstable`): какой Metamod

В пакете SM 1.11 два ядра: `sourcemod.2.ep1` (для MM 1.12) и `sourcemod.1.ep1` (для MM 1.10).
Какое из них запустится, решает Metamod:

| `--metamod` | Metamod | Ядро SM | DHooks | Старые плагины Metamod (PLAPI 7–12) |
|-------------|---------|---------|--------|-------------------------------------|
| `default` | 1.12.0 (`metamod.2.ep1`) | 2.ep1 | да | да, через мост на `metamod.1.ep1` из того же пакета |
| `legacy` | 1.10.7 (`metamod.1.ep1`) | 1.ep1 | нет | да, напрямую |

`legacy` нужен только для расширений SourceMod, собранных лишь под `.1.ep1`. `--metamod legacy`
есть только у `sm11-oldstable`; у остальных линий установщик откажет.

Линия `sm11-oldstable` заморожена, её пакеты не пересобираются. Чего в них не хватает,
установщик докладывает поверх пакетов: это список `hotfixes` линии в `manifest/sources.json`
(ссылка на коммит sourcemod-css34 и sha256 каждого файла). Сейчас там один файл —
`gamedata/core.games/custom/css34-hinttext-prebyte.txt` с `"HintTextPreByte" "yes"`: без
него клиент v34 не показывает `PrintHintText` и `sm_hsay`. SourceMod читает
`gamedata/<имя>.games/custom/*.txt` после штатных файлов, для обоих Metamod. `--smoke`
проверяет, что в `console.log` есть `[SM] Parsed custom gamedata override file: …` для
каждого такого файла.

MM и SM всегда ставятся парой из одного источника. Обновления SM выключены
(`"DisableAutoUpdate" "yes"` в `core.cfg`). Для SM 1.12+ без GeoIP2 в пакете установщик
докладывает `GeoLite2-Country.mmdb` (без неё не грузится `geoip.ext`, а за ним SMAC); новые наши
пакеты содержат её сами.

### SMAC

Берётся из ветки `master` [`smac_v34`](https://github.com/fmu1337/smac_v34). `--smac-mode auto`:
компилирует плагины `spcomp` из установленного SM (32-bit, нужны библиотеки из `--deps-only`);
если не вышло — берёт готовые `.smx` из репозитория SMAC. `compile` — только компиляция,
`prebuilt` — только готовые.

### ProtectCMDS

SM-расширение (только Linux), собирается здесь же (`extras/protectcmds/build.sh`,
workflow `protectcmds`) и лежит в релизе
[`protectcmds-bbdc766`](https://github.com/fmu1337/v34_server_base/releases/tag/protectcmds-bbdc766)
в двух вариантах: API 7 (SM 1.11/1.12) и API 9 (SM 1.13). Нужный выбирается по
`css34-package.json` нашего пакета SM, для rom4s/myarena — по версии SM. Ставится с
`protectcmds.ini` (апдейтер выключен, `osfix` выключен при `bufferfix`), `blockcmds.txt` и
плагином `protectcmds_status.smx`: клиентские `status`/`ping` уходят в защищённые `sm_status`/
`sm_ping` из SMAC. Подробно — [docs/PROTECTCMDS.md](docs/PROTECTCMDS.md).

## Все опции

```
./install.sh --help
```

Полезное:

- `--smoke` — после установки поднять сервер и проверить по RCON `meta version`,
  `sm version`, `sm exts list`, `sm plugins list`; для наших пакетов `meta version` должен
  показать версию и коммит из `css34-package.json` пакета Metamod (например `1.10.7-dev` и `80e8ff0`),
  а `console.log` — строку о каждом hotfix-файле линии;
- `--server-source skip` — доустановить / переустановить SM, патчи и плагины в уже
  существующий сервер;
- `--cache DIR` — общий кэш загрузок (ключ — тег/имя файла; файлы с sha256 в манифесте
  перепроверяются);
- `--sm-pinned` — ставить SM только из закреплённых тегов, без указателя линии;
- `--metamod legacy` — для `sm11-oldstable`: MM 1.10.7 вместо MM 1.12 (см. выше);
- `GITHUB_TOKEN=…` — передаётся в запросы к github.com (лимиты API, приватные форки).

## Устройство

```
install.sh                         установщик
manifest/sources.json              все ссылки (наши релизы, rom4s, myarena, SMAC, GeoIP) + sha256
patches/srcds_patch.py             бинарные патчи (bufferfix, steamclient, steamdeny, lanfix, hidecmds, …)
configs/valve-*.rc                 варианты valve.rc
extras/protectcmds/                сборка ProtectCMDS, его конфиги и плагин status/ping
lib/smoke.py                       smoke-тест через RCON
docs/                              патчи, ProtectCMDS, TODO
.github/workflows/test.yml         CI: полная установка + smoke (линии SM, rom4s, myarena, все патчи)
.github/workflows/server-files.yml релиз server-css34-4044 (файлы сервера rom4s, сверка sha256)
.github/workflows/protectcmds.yml  релиз protectcmds-<commit> (сборка на debian:11)
todo/windows/                      отложенный Windows-установщик (docs/TODO.md)
```
