#!/usr/bin/env python3
"""
Binary patches for the CS:S v34 Linux dedicated server (ELF32, i386).

Patches (pick with --only, default: bufferfix,steamclient):

  bufferfix    engine_{amd,i486,i686}.so, cstrike/bin/server_i486.so
               Retarget every `memcpy` relocation to `memmove` and zero the
               `memcpy` .dynsym/.gnu.version entry (bruno_args' srcds_patch).
               Overlapping memcpy on modern glibc -> hangs, `Unknown command ":"`.

  steamclient  bin/steamclient_i486.so
               Mute the three `Assertion Failed: !"Implement me!"` call sites.

  steamdeny    engine_*.so (from GoDtm666's status/ping protect engines)
               CSteam3::OnGSClientDenyHelper ignores NoLicense,
               SteamConnectionLost, SteamConnectionError and
               SteamValidationStalled instead of kicking the client.

  lanfix       engine_*.so (same source)
               CBaseServer::ConnectClient no longer rejects non-LAN clients with
               "LAN servers are restricted to local clients (class C)" when
               sv_lan is 1.

  hidecmds     engine_*.so
               Drop `status` and `ping` from the engine's list of commands a
               client may run (s_clcommands). Server console / rcon keep them;
               a client's `status` goes to the game DLL like any other command.
               (GoDtm666's engines renamed the list entries to ghor/dbause.)

  logonmsg     engine_*.so
               CSteam3::OnLogonFailure: mute "Could not establish connection to
               Steam servers." (printed with sv_lan 0).

  staticprop   engine_*.so
               CStaticProp::InsertPropIntoKDTree: mute "SOLID_VPHYSICS static
               prop with no vphysics model! (...)".

  botbuyzone   cstrike/bin/server_i486.so
               BuyState::OnUpdate: mute "<team> bot spawned outside of a buy
               zone (x, y, z)"; the bot still skips buying.

Every patch checks the original bytes before writing and recognises its own
result, so a second run reports "already". Stock files are kept as `*.orig`.

Usage:
  python3 patches/srcds_patch.py SERVER_DIR [--only bufferfix,steamdeny]
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

SHT_SYMTAB = 2
SHT_REL = 9
SHT_DYNSYM = 11
PT_LOAD = 1
R_386_NONE = 0

ENGINE_FILES = ("bin/engine_amd.so", "bin/engine_i486.so", "bin/engine_i686.so")
SERVER_FILE = "cstrike/bin/server_i486.so"
STEAMCLIENT_FILE = "bin/steamclient_i486.so"

ALL_PATCHES = ("bufferfix", "steamclient", "steamdeny", "lanfix",
               "hidecmds", "logonmsg", "staticprop", "botbuyzone")
DEFAULT_PATCHES = ("bufferfix", "steamclient")


class PatchError(Exception):
    pass


def _u16(data, off):
    return struct.unpack_from("<H", data, off)[0]


def _u32(data, off):
    return struct.unpack_from("<I", data, off)[0]


def _cstr(data, off):
    end = data.find(b"\x00", off)
    return bytes(data[off : end if end >= 0 else len(data)]).decode("latin1")


class Elf:
    """Just enough ELF32 parsing for the patches below."""

    def __init__(self, data: bytearray):
        if data[:4] != b"\x7fELF" or data[4] != 1:
            raise PatchError("not an ELF32 file")
        self.data = data
        shoff, shentsize, shnum, shstrndx = (
            _u32(data, 32), _u16(data, 46), _u16(data, 48), _u16(data, 50))
        self.sections = []
        for i in range(shnum):
            o = shoff + i * shentsize
            self.sections.append({
                "name_off": _u32(data, o), "type": _u32(data, o + 4),
                "addr": _u32(data, o + 12), "offset": _u32(data, o + 16),
                "size": _u32(data, o + 20), "link": _u32(data, o + 24),
                "entsize": _u32(data, o + 36),
            })
        strtab = self.sections[shstrndx]["offset"]
        for s in self.sections:
            s["name"] = _cstr(data, strtab + s["name_off"])
        phoff, phentsize, phnum = _u32(data, 28), _u16(data, 42), _u16(data, 44)
        self.loads = []
        for i in range(phnum):
            o = phoff + i * phentsize
            if _u32(data, o) == PT_LOAD:
                # (vaddr, offset, filesz)
                self.loads.append((_u32(data, o + 8), _u32(data, o + 4), _u32(data, o + 16)))

    def section(self, name):
        return next((s for s in self.sections if s["name"] == name), None)

    def off(self, vaddr: int) -> int:
        for va, fo, sz in self.loads:
            if va <= vaddr < va + sz:
                return vaddr - va + fo
        raise PatchError(f"address {vaddr:#x} is not in the file")

    def symbol(self, name: str) -> int | None:
        """Symbol value from .symtab (falls back to .dynsym)."""
        for sec in self.sections:
            if sec["type"] not in (SHT_SYMTAB, SHT_DYNSYM):
                continue
            strtab = self.sections[sec["link"]]["offset"]
            ent = sec["entsize"] or 16
            for i in range(sec["size"] // ent):
                o = sec["offset"] + i * ent
                if _cstr(self.data, strtab + _u32(self.data, o)) == name:
                    return _u32(self.data, o + 4)
        return None

    def need_symbol(self, name: str) -> int:
        v = self.symbol(name)
        if v is None:
            raise PatchError(f"symbol {name} not found")
        return v

    def rel_entries(self):
        """(file offset of the entry, r_offset, r_info) for .rel.dyn/.rel.plt."""
        for sec in self.sections:
            if sec["type"] != SHT_REL or sec["name"] not in (".rel.dyn", ".rel.plt"):
                continue
            ent = sec["entsize"] or 8
            for j in range(sec["size"] // ent):
                ro = sec["offset"] + j * ent
                yield ro, _u32(self.data, ro), _u32(self.data, ro + 4)

    def string_vaddr(self, text: bytes) -> int:
        sec = self.section(".rodata")
        i = self.data.find(text + b"\x00", sec["offset"], sec["offset"] + sec["size"])
        if i < 0:
            raise PatchError(f"string {text!r} not found")
        return sec["addr"] + i - sec["offset"]


# ---- bufferfix ---------------------------------------------------------------

def patch_bufferfix(elf: Elf) -> str:
    data = elf.data
    dynsym, dynstr = elf.section(".dynsym"), elf.section(".dynstr")
    versym = elf.section(".gnu.version")
    if not dynsym or not dynstr:
        raise PatchError("missing .dynsym/.dynstr")
    ent = dynsym["entsize"] or 16
    memcpy_idx = memmove_idx = None
    for i in range(dynsym["size"] // ent):
        name = _cstr(data, dynstr["offset"] + _u32(data, dynsym["offset"] + i * ent))
        if name == "memcpy" and memcpy_idx is None:
            memcpy_idx = i
        elif name == "memmove" and memmove_idx is None:
            memmove_idx = i
    if memcpy_idx is None and memmove_idx is not None:
        return "already"  # memcpy entry zeroed by a previous run
    if memcpy_idx is None or memmove_idx is None:
        raise PatchError("memcpy/memmove not both present")

    n = 0
    for ro, _, r_info in elf.rel_entries():
        if r_info >> 8 == memcpy_idx:
            struct.pack_into("<I", data, ro + 4, (memmove_idx << 8) | (r_info & 0xFF))
            n += 1
    so = dynsym["offset"] + memcpy_idx * ent
    data[so : so + ent] = b"\x00" * ent
    if versym and versym["entsize"] in (0, 2):
        struct.pack_into("<H", data, versym["offset"] + memcpy_idx * 2, 0)
    return f"{n} memcpy relocations -> memmove"


# ---- steamclient -------------------------------------------------------------

# mov DWORD PTR [esp], "Assertion Failed: !"Implement me!"" ; call rel32
STEAM_ASSERT_PAT = bytes.fromhex("c70424cca95e00e8fcffffff")
STEAM_ASSERT_REPL = bytes.fromhex("eb0a90909090909090909090")
# Only the three sites muted by srcds_patch (skip other uses of the string).
STEAM_ASSERT_AFTER = (
    bytes.fromhex("8b45088b4018c9c3"),
    bytes.fromhex("83c4205b5e5dc389"),
)


def _find_sites(data, pat):
    out, start = [], 0
    while (i := data.find(pat, start)) >= 0:
        if bytes(data[i + 12 : i + 20]) in STEAM_ASSERT_AFTER:
            out.append(i)
        start = i + 1
    return out


def patch_steamclient(elf: Elf) -> str:
    data = elf.data
    todo, done = _find_sites(data, STEAM_ASSERT_PAT), _find_sites(data, STEAM_ASSERT_REPL)
    if len(todo) + len(done) != 3:
        raise PatchError(f"expected 3 assertion sites, found {len(todo) + len(done)}")
    if not todo:
        return "already"
    for i in todo:
        data[i : i + 12] = STEAM_ASSERT_REPL
    return f"muted {len(todo)} assertion site(s)"


# ---- steamdeny ---------------------------------------------------------------

# EDenyReason values that no longer kick the client.
DENY_IGNORED = {4: "NoLicense", 11: "SteamConnectionLost",
                12: "SteamConnectionError", 14: "SteamValidationStalled"}


def patch_steamdeny(elf: Elf) -> str:
    data = elf.data
    va = elf.need_symbol("_ZN7CSteam320OnGSClientDenyHelperEP11CBaseClient11EDenyReasonPKc")
    f = elf.off(va)
    body = bytes(data[f : f + 0x200])
    if b"\x83\xf8\x0e" not in body[:0x20]:
        raise PatchError("EDenyReason switch not found")
    j = body.find(b"\xff\x24\x85")  # jmp *table(,%eax,4)
    if j < 0 or j > 0x20:
        raise PatchError("jump table not found")
    table = elf.off(_u32(body, j + 3))
    # Plain return of the function: first `ret`, together with the stack
    # cleanup in front of it when the function has a frame.
    r = body.find(b"\xc3", j)
    if r < 0:
        raise PatchError("return not found")
    ret = va + (r - 3 if body[r - 3 : r] == b"\x83\xc4\x0c" else r)
    changed = 0
    for idx in DENY_IGNORED:
        cur = _u32(data, table + idx * 4)
        if cur == ret:
            continue
        if not va < cur < va + 0x200:
            raise PatchError(f"unexpected jump table entry {idx}: {cur:#x}")
        struct.pack_into("<I", data, table + idx * 4, ret)
        changed += 1
    if not changed:
        return "already"
    return "ignore deny: " + ", ".join(DENY_IGNORED.values())


# ---- lanfix ------------------------------------------------------------------

LAN_JE_NOP = bytes.fromhex("6689c06689c0")  # 2x mov %ax,%ax, as in GoDtm666's engines


def patch_lanfix(elf: Elf) -> str:
    data = elf.data
    va = elf.need_symbol("_ZN11CBaseServer13ConnectClientER8netadr_siiiPKcS3_S3_iS3_i")
    f = elf.off(va)
    msg = struct.pack("<I", elf.string_vaddr(b"LAN servers are restricted to local clients (class C).\n"))
    m = data.find(msg, f, f + 0x800)
    if m < 0:
        raise PatchError("LAN restriction message not found")
    if data.find(LAN_JE_NOP, f, m) >= 0:
        return "already"
    # je rel32 whose target is the block that loads the message
    for i in range(f, m):
        if data[i] == 0x0F and data[i + 1] == 0x84:
            target = i + 6 + struct.unpack_from("<i", data, i + 2)[0]
            if target <= m < target + 12:
                data[i : i + 6] = LAN_JE_NOP
                return "LAN-only rejection removed"
    raise PatchError("LAN restriction check not found")


# ---- hidecmds ----------------------------------------------------------------

# Engine commands a client may run (CGameClient::ExecuteStringCommand runs a
# client string through Cmd_ExecuteString only if its first word is in the
# NULL-terminated `s_clcommands` list; anything else goes to the game DLL).
# GoDtm666's engines rename these entries (status -> dbause/debuus,
# ping -> ghor/enrs), which leaves status/ping open under the new names.
HIDDEN_CLCOMMANDS = ("status", "ping", "dbause", "debuus", "ghor", "enrs")


def patch_hidecmds(elf: Elf) -> str:
    data = elf.data
    va = elf.need_symbol("s_clcommands")
    base = elf.off(va)
    # slot vaddr -> file offset of its R_386_RELATIVE relocation
    relocs = {r_off: ro for ro, r_off, r_info in elf.rel_entries() if r_info == 8}
    names = []
    while (p := _u32(data, base + len(names) * 4)) != 0:
        names.append((p, _cstr(data, elf.off(p))))
        if len(names) > 32:
            raise PatchError("s_clcommands is not NULL-terminated")
    keep = [(p, n) for p, n in names if n not in HIDDEN_CLCOMMANDS]
    if len(keep) == len(names):
        return "already"
    if not keep:
        raise PatchError("nothing left in s_clcommands")
    # Pack the remaining entries to the front, end the list early. A slot
    # turned into the terminator must lose its relocation, or the loader
    # would add the load base to the 0.
    for i, (p, _) in enumerate(keep):
        struct.pack_into("<I", data, base + i * 4, p)
    for i in range(len(keep), len(names)):
        ro = relocs.get(va + i * 4)
        if ro is None:
            raise PatchError(f"no relocation for s_clcommands[{i}]")
        struct.pack_into("<I", data, base + i * 4, 0)
        struct.pack_into("<I", data, ro + 4, R_386_NONE)
    hidden = [n for _, n in names if n in HIDDEN_CLCOMMANDS]
    return "client can't run: " + ", ".join(hidden)


# ---- logonmsg / staticprop / botbuyzone (console noise) ----------------------

def _str_call(elf: Elf, symbol: str, size: int, text: bytes):
    """The one `<pass text as 1st arg>; call rel32` in the function.

    The arg is `mov dword ptr [esp], imm32` in i486/i686 builds and
    `push imm32` in amd. Returns (file offset of that insn, offset after the
    call and after an `add esp, imm8` stack cleanup if there is one)."""
    data = elf.data
    f = elf.off(elf.need_symbol(symbol))
    imm = struct.pack("<I", elf.string_vaddr(text))
    hits = []
    for insn in (b"\xc7\x04\x24" + imm, b"\x68" + imm):
        i = f
        while (i := data.find(insn, i, f + size)) >= 0:
            hits.append((i, i + len(insn)))
            i += 1
    if len(hits) != 1:
        raise PatchError(f"expected one use of {text[:40]!r}, found {len(hits)}")
    ref, call = hits[0]
    if data[call] != 0xE8:
        raise PatchError(f"no call after {text[:40]!r}")
    after = call + 5
    if data[after : after + 2] == b"\x83\xc4":
        after += 3
    return ref, after


def patch_logonmsg(elf: Elf) -> str:
    # CSteam3::OnLogonFailure: `if (!sv_lan) Msg("Could not establish ...")`.
    # The jne over the Msg becomes jmp; the state flags are still set.
    data = elf.data
    ref, after = _str_call(elf, "_ZN7CSteam314OnLogonFailureEP14LogonFailure_t", 0x80,
                           b"Could not establish connection to Steam servers.\n")
    for i in range(ref - 2, ref - 8, -1):
        if data[i] in (0x75, 0xEB) and i + 2 + data[i + 1] >= after:
            break
    else:
        raise PatchError("sv_lan check in front of the message not found")
    if data[i] == 0xEB:
        return "already"
    data[i] = 0xEB
    return "muted 'Could not establish connection to Steam servers.'"


def patch_staticprop(elf: Elf) -> str:
    # CStaticProp::InsertPropIntoKDTree, model without a vphysics collide:
    #   pCollide = CM_VCollideForModel(-1, model);
    #   if (!pCollide || !pCollide->solidCount) {
    #       Q_strncpy(buf, ...); Warning("SOLID_VPHYSICS static prop ...");   <- skipped
    #       m_nSolidType = SOLID_NONE; return; }
    # A short jmp at the start of that block lands right after Warning()
    # (and its stack cleanup in amd), so the stack stays balanced.
    data = elf.data
    sym = "_ZN11CStaticProp20InsertPropIntoKDTreeEv"
    ref, after = _str_call(elf, sym, 0x400,
                           b"SOLID_VPHYSICS static prop with no vphysics model! (%s)\n")
    # je <block> ; test word ptr [eax], 0x7fff (solidCount)
    k = data.find(b"\x66\xf7\x00\xff\x7f", ref - 0x40, ref)
    if k < 0 or data[k - 2] != 0x74:
        raise PatchError("vcollide check not found")
    start = k + data[k - 1]
    if not k < start < ref or after - (start + 2) > 0x7F:
        raise PatchError("unexpected block layout")
    jmp = bytes([0xEB, after - (start + 2)])
    if data[start : start + 2] == jmp:
        return "already"
    data[start : start + 2] = jmp
    return "muted 'SOLID_VPHYSICS static prop with no vphysics model!'"


def patch_botbuyzone(elf: Elf) -> str:
    # BuyState::OnUpdate, bot outside a buy zone:
    #   m_doneBuying = true;
    #   if (EFL_DIRTY_ABSTRANSFORM) CalcAbsolutePosition();    <- jne here
    #   CONSOLE_ECHO("%s bot spawned outside of a buy zone (%d, %d, %d)\n", ...);
    #   return;
    # The jne becomes a jmp to that `return`.
    data = elf.data
    m, after = _str_call(elf, "_ZN8BuyState8OnUpdateEP6CCSBot", 0x1000,
                         b"%s bot spawned outside of a buy zone (%d, %d, %d)\n")
    if data[after] != 0xE9:
        raise PatchError("return after CONSOLE_ECHO not found")
    exit_off = after + 5 + struct.unpack_from("<i", data, after + 1)[0]
    # mov byte ptr [ebp+0x14], 1 ; jne/jmp rel32
    i = data.rfind(b"\xc6\x45\x14\x01", m - 0x80, m)
    if i < 0:
        raise PatchError("m_doneBuying store not found")
    j = i + 4
    jmp = b"\xe9" + struct.pack("<i", exit_off - (j + 5)) + b"\x90"
    if data[j : j + 6] == jmp:
        return "already"
    if data[j : j + 2] != b"\x0f\x85":
        raise PatchError("EFL_DIRTY_ABSTRANSFORM check not found")
    data[j : j + 6] = jmp
    return "muted 'bot spawned outside of a buy zone'"


# ---- driver ------------------------------------------------------------------

ENGINE_PATCHES = (
    ("bufferfix", patch_bufferfix), ("steamdeny", patch_steamdeny),
    ("lanfix", patch_lanfix), ("hidecmds", patch_hidecmds),
    ("logonmsg", patch_logonmsg), ("staticprop", patch_staticprop),
)
SERVER_PATCHES = (("bufferfix", patch_bufferfix), ("botbuyzone", patch_botbuyzone))


def plan(patches):
    """file -> list of (patch name, function)"""
    todo: dict[str, list] = {}
    for rel in ENGINE_FILES:
        for name, fn in ENGINE_PATCHES:
            if name in patches:
                todo.setdefault(rel, []).append((name, fn))
    for name, fn in SERVER_PATCHES:
        if name in patches:
            todo.setdefault(SERVER_FILE, []).append((name, fn))
    if "steamclient" in patches:
        todo.setdefault(STEAMCLIENT_FILE, []).append(("steamclient", patch_steamclient))
    return todo


def backup(path: Path) -> None:
    orig = path.with_name(path.name + ".orig")
    if not orig.exists():
        orig.write_bytes(path.read_bytes())


def patch_tree(server_dir: Path, patches) -> int:
    rc = 0
    for rel, steps in plan(patches).items():
        path = server_dir / rel
        if not path.is_file():
            print(f"FAIL {rel}: missing", file=sys.stderr)
            rc = 1
            continue
        data = bytearray(path.read_bytes())
        elf = Elf(data)
        changed = False
        for name, fn in steps:
            try:
                res = fn(elf)
            except PatchError as e:
                print(f"FAIL {rel} [{name}]: {e}", file=sys.stderr)
                rc = 1
                continue
            print(f"OK   {rel} [{name}]: {res}")
            changed |= res != "already"
        if changed:
            backup(path)
            path.write_bytes(data)
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("server_dir", type=Path, help="server root (contains bin/ and cstrike/)")
    ap.add_argument("--only", default=",".join(DEFAULT_PATCHES),
                    help=f"comma separated: {','.join(ALL_PATCHES)} (default: %(default)s)")
    args = ap.parse_args()
    patches = {p for p in args.only.split(",") if p}
    unknown = patches - set(ALL_PATCHES)
    if unknown:
        ap.error(f"unknown patch: {', '.join(sorted(unknown))}")
    if not args.server_dir.is_dir():
        ap.error(f"not a directory: {args.server_dir}")
    return patch_tree(args.server_dir, patches)


if __name__ == "__main__":
    sys.exit(main())
