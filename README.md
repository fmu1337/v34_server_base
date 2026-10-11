# v34_server_base

Установщик базового сервера **CS:S v34**: файлы сервера, патчи бинарей, Metamod + SourceMod,
доп. плагины. Основная платформа — Linux, Windows тоже поддерживается.

## Быстрый старт

Linux:

```bash
git clone https://github.com/fmu1337/v34_server_base && cd v34_server_base
sudo ./install.sh --deps-only        # 32-bit библиотеки (apt / dnf), один раз
./install.sh                         # интерактивное меню
./install.sh -y --dir /srv/css34     # всё по умолчанию, без вопросов
/srv/css34/start-server.sh
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Dir C:\css34
C:\css34\start-server.bat
```

## Что ставится

| Шаг | По умолчанию | Варианты |
|-----|--------------|----------|
| Файлы сервера | релиз [`v34_srcds_server`](https://github.com/fmu1337/v34_srcds_server/releases/tag/css34-4044), при ошибке — bitbucket rom4s | `--server-source auto\|mirror\|rom4s\|skip` |
| Патчи | `bufferfix,steamclient,healthfix` (Windows: `healthfix`) | + `steamdeny`, `lanfix`; `--patch LIST\|all\|none`, `--valve-rc auto\|stock\|debian9\|minimal` |
| Metamod + SourceMod | наш [`sourcemod-css34`](https://github.com/fmu1337/sourcemod-css34), линия `sm13-latest` | `--sm ours\|rom4s\|myarena\|none`, `--sm-line …` |
| Плагины | SMAC ([`smac_v34`](https://github.com/fmu1337/smac_v34)) | `--plugins smac\|none`, `--smac-mode auto\|compile\|prebuilt` |

Описание патчей — [docs/PATCHES.md](docs/PATCHES.md).

### SourceMod

| `--sm` | Metamod | SourceMod | Платформы |
|--------|---------|-----------|-----------|
| `ours` `sm13-latest` | 1.12.0-dev+1226 | 1.13.0.7472 | Linux, Windows |
| `ours` `sm13-dev` | 1.12.0-dev+1226 | 1.13.0.7404 | Linux, Windows |
| `ours` `sm12-latest` | 1.12.0-dev+1226 | 1.12.0.7253 | Linux, Windows |
| `ours` `sm13-mm20-khook` | 2.0.0-dev (KHook) | 1.13.0.7565 + dhooks | только Linux |
| `rom4s` | 1.10.6 (Windows: наш 1.10.7, у rom4s нет Windows-сборки) | 1.11.0.6572 | Linux, Windows |
| `myarena` | 1.11.0-1130 | 1.11.0.6522 (git6541, fix gamedata 12.10.2020) | только Linux |

SM 1.11 — это `rom4s` или `myarena`: у нашего релиза `1.11.0.6970-mm1.10.7` нет файлов, а
`1.11.0.6572-mm1.10.7` падает (segfault) при загрузке карты.

MM и SM всегда ставятся парой из одного источника. Для SM 1.12+ установщик докладывает
GeoIP2 `GeoLite2-Country.mmdb` (без неё не грузится `geoip.ext`, а за ним SMAC).

### SMAC

`auto`: компилирует плагины `spcomp` из установленного SM (32-bit, нужны библиотеки из
`--deps-only`); если не вышло — берёт готовые `.smx` из репозитория.

## Все опции

```
./install.sh --help
Get-Help .\install.ps1 -Detailed
```

Полезное:

- `--smoke` — после установки поднять сервер и проверить по RCON `meta version`,
  `sm version`, `sm exts list`, `sm plugins list`;
- `--server-source skip` — доустановить / переустановить SM, патчи и плагины в уже
  существующий сервер;
- `--cache DIR` — общий кэш загрузок;
- `GITHUB_TOKEN=…` — если репозиторий с зеркалом приватный.

## Устройство

```
install.sh / install.ps1        установщики
manifest/sources.json           все ссылки (зеркало, rom4s, myarena, наши релизы) + sha256
patches/srcds_patch.py          бинарные патчи (bufferfix, steamclient, healthfix, steamdeny, lanfix)
patches/healthfix/              HealthLimitFix как SM-плагин (для Windows)
configs/valve-*.rc              варианты valve.rc
lib/smoke.py                    smoke-тест через RCON
.github/workflows/test.yml      CI: полная установка + smoke на Linux и Windows
```
