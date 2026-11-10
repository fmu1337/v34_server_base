# v34_server_base

Установщик сервера **CS:S v34** под Linux одной командой: файлы сервера, бинарные патчи
движка, Metamod + SourceMod, SMAC и ProtectCMDS.

## Как пользоваться

```bash
git clone https://github.com/fmu1337/v34_server_base && cd v34_server_base
sudo ./install.sh --deps-only        # 32-bit библиотеки, один раз
./install.sh                         # интерактивное меню
./install.sh -y --dir /srv/css34     # или всё по умолчанию, без вопросов
/srv/css34/start-server.sh
```

Частые варианты:

```bash
./install.sh -y --dir /srv/css34 --patch all                 # все патчи
./install.sh -y --dir /srv/css34 --server-source skip ...    # доставить в готовый сервер
./install.sh -y --dir /srv/css34 --sm-line sm12-latest       # другая линия SourceMod
./install.sh --help                                          # все опции
```

## Что ставится

| Шаг | По умолчанию | Опции |
|-----|--------------|-------|
| Файлы сервера | релиз [`server-css34-4044`](https://github.com/fmu1337/v34_server_base/releases/tag/server-css34-4044) (копия rom4s) | `--server-source auto\|mirror\|rom4s\|skip` |
| Патчи | `bufferfix,steamclient` | `--patch LIST\|all\|none` — [docs/PATCHES.md](docs/PATCHES.md) |
| Metamod + SourceMod | [`sourcemod-css34`](https://github.com/fmu1337/sourcemod-css34), `sm13-latest` | `--sm ours\|rom4s\|myarena\|none`, `--sm-line …` — [docs/SOURCEMOD.md](docs/SOURCEMOD.md) |
| Плагины | [SMAC](https://github.com/fmu1337/smac_v34) + [ProtectCMDS](https://github.com/fmu1337/ProtectCMDS) | `--plugins smac,protectcmds\|none` — [docs/PROTECTCMDS.md](docs/PROTECTCMDS.md) |

Патчи: `bufferfix` (зависания на новой glibc), `steamclient`, `steamdeny`, `lanfix`,
`hidecmds` (клиенты не могут вызвать `status`/`ping`), `logonmsg`, `staticprop`, `botbuyzone`
(глушат спам в консоли). Отдельно, без установщика:

```bash
python3 patches/srcds_patch.py /srv/css34 --only hidecmds,logonmsg
```

`--smoke` после установки поднимает сервер и проверяет Metamod, SourceMod и плагины по RCON.
Windows пока отложен — [docs/TODO.md](docs/TODO.md).
