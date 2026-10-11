#!/usr/bin/env python3
"""
Binary patches for the CS:S v34 Linux dedicated server (ELF32, i386).

Patches (pick with --only, default: bufferfix,steamclient,healthfix):

  bufferfix    engine_{amd,i486,i686}.so, cstrike/bin/server_i486.so
               Retarget every `memcpy` relocation to `memmove` and zero the
               `memcpy` .dynsym/.gnu.version entry (bruno_args' srcds_patch).
               Overlapping memcpy on modern glibc -> hangs, `Unknown command ":"`.

  steamclient  bin/steamclient_i486.so
               Mute the three `Assertion Failed: !"Implement me!"` call sites.

  healthfix    cstrike/bin/server_i486.so + engine_*.so (HealthLimitFix by
               Reg1oxeN, done statically instead of from a SourceMod plugin)
               - DT_BasePlayer `m_iHealth` SendProp: nBits 10 -> 17
               - SendTable_GetCRC() returns 1337 so clients take the server's
                 tables (needs sv_sendtables 1)

  steamdeny    engine_*.so (from GoDtm666's status/ping protect engines)
               CSteam3::OnGSClientDenyHelper ignores NoLicense,
               SteamConnectionLost, SteamConnectionError and
               SteamValidationStalled instead of kicking the client.

  lanfix       engine_*.so (same source)
               CBaseServer::ConnectClient no longer rejects non-LAN clients with
               "LAN servers are restricted to local clients (class C)" when
               sv_lan is 1.

Every patch checks the original bytes before writing and recognises its own
result, so a second run reports "already". Stock files are kept as `*.orig`.

Usage:
  python3 patches/srcds_patch.py SERVER_DIR [--only bufferfix,healthfix]
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

ALL_PATCHES = ("bufferfix", "steamclient", "healthfix", "steamdeny", "lanfix")
DEFAULT_PATCHES = ("bufferfix", "steamclient", "healthfix")


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


# ---- healthfix ---------------------------------------------------------------

HEALTH_BITS_OLD, HEALTH_BITS_NEW = 10, 17
SENDTABLE_CRC = 1337


def patch_health_server(elf: Elf) -> str:
    """nBits argument of SendPropInt("m_iHealth", ...) in ServerClassInit<DT_BasePlayer>."""
    data = elf.data
    func = elf.off(elf.need_symbol("_Z15ServerClassInitIN13DT_BasePlayer7ignoredEEiPT_"))
    name = struct.pack("<I", elf.string_vaddr(b"m_iHealth"))
    # mov $"m_iHealth", %reg  (b8+r imm32)
    p = next((i for i in range(func, func + 0x2000)
              if 0xB8 <= data[i] <= 0xBF and data[i + 1 : i + 5] == name), None)
    if p is None:
        raise PatchError("m_iHealth SendProp not found")
    # The argument block of this SendPropInt call ends at the next `call`;
    # arguments are stored with `mov %reg, disp8(%esp)` and nBits is the 4th
    # argument after the sret pointer: 0x10(%esp).
    call = data.find(b"\xe8", p + 5, p + 0x40)
    prev = data.rfind(b"\xe8", p - 0x60, p)  # end of the previous SendProp call
    lo = prev + 5 if prev >= 0 else p - 0x40
    if call < 0:
        raise PatchError("SendPropInt call not found")
    store = next((i for i in range(call - 4, lo - 1, -1)
                  if data[i] == 0x89 and data[i + 1] & 0xC7 == 0x44
                  and data[i + 2] == 0x24 and data[i + 3] == 0x10), None)
    if store is None:
        raise PatchError("nBits store not found")
    reg = (data[store + 1] >> 3) & 7
    for i in range(store - 5, lo - 1, -1):
        if data[i] == 0xB8 + reg:
            bits = _u32(data, i + 1)
            if bits == HEALTH_BITS_NEW:
                return "already"
            if bits != HEALTH_BITS_OLD:
                raise PatchError(f"unexpected m_iHealth nBits {bits}")
            struct.pack_into("<I", data, i + 1, HEALTH_BITS_NEW)
            return f"m_iHealth nBits {HEALTH_BITS_OLD} -> {HEALTH_BITS_NEW}"
    raise PatchError("nBits immediate not found")


def patch_health_engine(elf: Elf) -> str:
    """SendTable_GetCRC: `mov g_SendTableCRC, %eax; ret` -> `mov $1337, %eax; ret`."""
    data = elf.data
    va = elf.need_symbol("_Z16SendTable_GetCRCv")
    o = elf.off(va)
    new = b"\xb8" + struct.pack("<I", SENDTABLE_CRC) + b"\xc3"
    if data[o : o + 6] == new:
        return "already"
    if data[o] != 0xA1 or data[o + 5] != 0xC3:
        raise PatchError("unexpected SendTable_GetCRC code")
    # The load address is filled in by an R_386_32 relocation; drop it so the
    # loader does not add a symbol address to our constant.
    rel = [ro for ro, r_off, _ in elf.rel_entries() if r_off == va + 1]
    if len(rel) != 1:
        raise PatchError("SendTable_GetCRC relocation not found")
    data[rel[0] + 4] = R_386_NONE
    data[o : o + 6] = new
    return f"SendTable_GetCRC returns {SENDTABLE_CRC}"


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


# ---- driver ------------------------------------------------------------------

def plan(patches):
    """file -> list of (patch name, function)"""
    todo: dict[str, list] = {}
    for rel in ENGINE_FILES:
        for name, fn in (("bufferfix", patch_bufferfix), ("healthfix", patch_health_engine),
                         ("steamdeny", patch_steamdeny), ("lanfix", patch_lanfix)):
            if name in patches:
                todo.setdefault(rel, []).append((name, fn))
    for name, fn in (("bufferfix", patch_bufferfix), ("healthfix", patch_health_server)):
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
