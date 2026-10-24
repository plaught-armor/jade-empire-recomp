#!/usr/bin/env python3
"""Unpack the PECompact2-packed JadeEmpire.exe by emulating its loader stub.

The stub is run under unicorn with a fake kernel32 (LoadLibraryA,
GetProcAddress, VirtualAlloc, VirtualFree, plus whatever the stub resolves
itself). Emulation stops at the first instruction executed inside the
original code range: the original entry point (OEP). The image is dumped
at that moment, so .data still holds its link-time contents (no CRT
initialisers have run), and every API the stub resolved is known by name,
which lets the import table be rebuilt exactly.

Usage: unpack_pec2.py <packed.exe> <out.exe>
"""

import struct
import sys

import pefile
from unicorn import (UC_ARCH_X86, UC_HOOK_CODE, UC_HOOK_MEM_INVALID,
                     UC_MODE_32, Uc, UcError)
from unicorn.x86_const import (UC_X86_REG_EAX, UC_X86_REG_EIP,
                               UC_X86_REG_ESP)

STACK_BASE = 0x00100000
STACK_SIZE = 0x00100000
HEAP_BASE = 0x10000000
HEAP_SIZE = 0x04000000
API_BASE = 0x70000000  # fake DLL handles + API stubs live here
API_DLL_STRIDE = 0x00100000

# Code range of the original program; the stub lives above it.
ORIG_CODE_START = 0x00401000
ORIG_CODE_END = 0x00895000
TRAMPOLINE_SIZE = 7


def align(v, a):
    return (v + a - 1) & ~(a - 1)


class Unpacker:
    def __init__(self, path):
        self.pe = pefile.PE(path)
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.size = self.pe.OPTIONAL_HEADER.SizeOfImage
        self.uc = Uc(UC_ARCH_X86, UC_MODE_32)
        self.dlls = {}        # lowercased dll name -> handle
        self.apis = {}        # stub address -> (dll, name)
        self.next_api = {}    # dll handle -> next free stub address
        self.heap_top = HEAP_BASE
        self.oep = None

    # -- memory setup -------------------------------------------------
    def load_image(self):
        uc, pe = self.uc, self.pe
        uc.mem_map(self.base, align(self.size, 0x1000))
        uc.mem_write(self.base, pe.header)
        for s in pe.sections:
            data = s.get_data()
            uc.mem_write(self.base + s.VirtualAddress, data)
        uc.mem_map(STACK_BASE, STACK_SIZE)
        uc.mem_map(HEAP_BASE, HEAP_SIZE)
        uc.mem_map(API_BASE, 0x10000000)
        # Stubs are `ret` so a hooked call always has a valid target; the
        # code hook performs the API and fixes up the stack.
        uc.mem_write(API_BASE, b"\xc3" * 0x1000)

    def dll_handle(self, name):
        key = name.lower()
        if not key.endswith(".dll"):
            key += ".dll"
        if key not in self.dlls:
            h = API_BASE + API_DLL_STRIDE * (len(self.dlls) + 1)
            self.dlls[key] = h
            self.next_api[h] = h + 0x1000
            # Each fake DLL gets a page of `ret` stubs per 4 KiB used.
            self.uc.mem_write(h, b"\xc3" * API_DLL_STRIDE)
        return self.dlls[key]

    def api_stub(self, dll, name):
        h = self.dll_handle(dll)
        for addr, (d, n) in self.apis.items():
            if d == dll.lower() and n == name:
                return addr
        addr = self.next_api[h]
        self.next_api[h] += 4
        self.apis[addr] = (dll.lower(), name)
        return addr

    def read_cstr(self, addr):
        out = bytearray()
        while True:
            b = self.uc.mem_read(addr, 1)[0]
            if b == 0:
                return out.decode("latin-1")
            out.append(b)
            addr += 1

    def alloc(self, size):
        addr = self.heap_top
        self.heap_top = align(self.heap_top + size, 0x1000)
        if self.heap_top > HEAP_BASE + HEAP_SIZE:
            raise RuntimeError("fake heap exhausted")
        return addr

    # -- fake kernel32 ------------------------------------------------
    def arg(self, i):
        esp = self.uc.reg_read(UC_X86_REG_ESP)
        return struct.unpack("<I", self.uc.mem_read(esp + 4 + 4 * i, 4))[0]

    def api_return(self, value, nargs):
        uc = self.uc
        esp = uc.reg_read(UC_X86_REG_ESP)
        ret = struct.unpack("<I", uc.mem_read(esp, 4))[0]
        uc.reg_write(UC_X86_REG_EAX, value & 0xFFFFFFFF)
        uc.reg_write(UC_X86_REG_ESP, esp + 4 + 4 * nargs)
        uc.reg_write(UC_X86_REG_EIP, ret)

    def call_api(self, dll, name):
        a = self.arg
        if name == "LoadLibraryA":
            self.api_return(self.dll_handle(self.read_cstr(a(0))), 1)
        elif name == "GetModuleHandleA":
            p = a(0)
            self.api_return(self.base if p == 0
                            else self.dll_handle(self.read_cstr(p)), 1)
        elif name == "GetProcAddress":
            h, p = a(0), a(1)
            dll = next(k for k, v in self.dlls.items() if v == h)
            sym = "#%d" % p if p < 0x10000 else self.read_cstr(p)
            self.api_return(self.api_stub(dll, sym), 2)
        elif name == "VirtualAlloc":
            want, size = a(0), a(1)
            self.api_return(want if want else self.alloc(size), 4)
        elif name == "FreeLibrary":
            self.api_return(1, 1)
        elif name == "VirtualFree":
            self.api_return(1, 3)
        elif name == "VirtualProtect":
            old = a(3)
            if old:
                self.uc.mem_write(old, struct.pack("<I", 0x40))
            self.api_return(1, 4)
        # Steam DRM wrapper (steam.dll, 2007 API): cdecl, caller pops args.
        # TSteamError starts with three ints; zero them to report success.
        elif name == "SteamStartup":
            self.uc.mem_write(a(1), bytes(12))
            self.api_return(1, 0)
        elif name == "SteamIsAppSubscribed":
            self.uc.mem_write(a(1), struct.pack("<I", 1))  # subscribed
            self.uc.mem_write(a(2), struct.pack("<I", 0))  # not pending
            self.uc.mem_write(a(3), bytes(12))
            self.api_return(1, 0)
        elif name == "SteamCleanup":
            self.uc.mem_write(a(0), bytes(12))
            self.api_return(1, 0)
        else:
            esp = self.uc.reg_read(UC_X86_REG_ESP)
            ret = struct.unpack("<I", self.uc.mem_read(esp, 4))[0]
            raise RuntimeError("stub called unhandled API %s!%s from %#x args %s"
                               % (dll, name, ret,
                                  [hex(a(i)) for i in range(4)]))

    # -- hooks ----------------------------------------------------------
    def on_code(self, uc, addr, size, _):
        if addr in self.apis:
            dll, name = self.apis[addr]
            self.call_api(dll, name)
            return
        # The packed entry is a 7-byte `mov eax, stub; jmp eax` trampoline
        # inside the original code range; the OEP is the first original
        # instruction executed outside it.
        entry = self.base + self.pe.OPTIONAL_HEADER.AddressOfEntryPoint
        if ORIG_CODE_START <= addr < ORIG_CODE_END and \
                not entry <= addr < entry + TRAMPOLINE_SIZE:
            self.oep = addr
            uc.emu_stop()

    def on_bad_mem(self, uc, access, addr, size, value, _):
        eip = uc.reg_read(UC_X86_REG_EIP)
        print("invalid memory access %d at %#x (eip %#x)" % (access, addr, eip))
        return False

    # -- run ------------------------------------------------------------
    def patch_packer_iat(self):
        for entry in self.pe.DIRECTORY_ENTRY_IMPORT:
            dll = entry.dll.decode()
            for imp in entry.imports:
                stub = self.api_stub(dll, imp.name.decode())
                self.uc.mem_write(imp.address, struct.pack("<I", stub))

    def run(self):
        uc = self.uc
        self.load_image()
        self.patch_packer_iat()
        uc.hook_add(UC_HOOK_CODE, self.on_code, begin=ORIG_CODE_START,
                    end=ORIG_CODE_END - 1)
        uc.hook_add(UC_HOOK_CODE, self.on_code, begin=API_BASE,
                    end=API_BASE + 0x10000000 - 1)
        uc.hook_add(UC_HOOK_MEM_INVALID, self.on_bad_mem)
        esp = STACK_BASE + STACK_SIZE - 0x100
        uc.mem_write(esp, struct.pack("<I", 0))  # return address of entry
        uc.reg_write(UC_X86_REG_ESP, esp)
        entry = self.base + self.pe.OPTIONAL_HEADER.AddressOfEntryPoint
        try:
            uc.emu_start(entry, 0)
        except UcError as e:
            raise RuntimeError("emulation failed at %#x: %s"
                               % (uc.reg_read(UC_X86_REG_EIP), e))
        if self.oep is None:
            raise RuntimeError("stub returned without reaching original code")
        return bytes(uc.mem_read(self.base, self.size))


def find_iat(image, apis):
    """Return [(rva, dll, name)] for every image dword holding an API stub."""
    slots = []
    for off in range(0, len(image) - 3, 4):
        v = struct.unpack_from("<I", image, off)[0]
        if v in apis:
            slots.append((off, apis[v][0], apis[v][1]))
    return slots


def group_thunks(slots):
    """Split IAT slots into per-DLL contiguous runs (null-terminated)."""
    runs = []
    for rva, dll, name in slots:
        if runs and runs[-1][0] == dll and runs[-1][1] + 4 * len(runs[-1][2]) == rva:
            runs[-1][2].append(name)
        else:
            runs.append([dll, rva, [name]])
    return runs


def build_import_section(runs, sect_rva):
    """Lay out descriptors, ILTs and hint/name entries at sect_rva."""
    desc_size = 20 * (len(runs) + 1)
    blob = bytearray(desc_size)
    descs = []
    for dll, iat_rva, names in runs:
        ilt_rva = sect_rva + len(blob)
        blob += bytes(4 * (len(names) + 1))
        entries = []
        for n in names:
            if n.startswith("#"):
                entries.append(0x80000000 | int(n[1:]))
            else:
                hn_rva = sect_rva + len(blob)
                blob += b"\0\0" + n.encode() + b"\0"
                if len(blob) & 1:
                    blob += b"\0"
                entries.append(hn_rva)
        struct.pack_into("<%dI" % len(entries), blob, ilt_rva - sect_rva, *entries)
        name_rva = sect_rva + len(blob)
        blob += dll.encode() + b"\0"
        descs.append((ilt_rva, name_rva, iat_rva, entries))
    for i, (ilt, name, iat, _) in enumerate(descs):
        struct.pack_into("<5I", blob, 20 * i, ilt, 0, 0, name, iat)
    return blob, descs


def write_pe(path, image, unp, runs):
    pe = unp.pe
    base = unp.base
    image = bytearray(image)
    fa = pe.OPTIONAL_HEADER.FileAlignment
    sa = pe.OPTIONAL_HEADER.SectionAlignment

    # IAT slots hold fake stub addresses; point them at hint/name entries
    # (what an unbound on-disk IAT contains) once the section is laid out.
    imp_rva = align(len(image), sa)
    blob, descs = build_import_section(runs, imp_rva)
    for _, _, iat_rva, entries in descs:
        struct.pack_into("<%dI" % (len(entries) + 1), image, iat_rva,
                         *(entries + [0]))

    oh = pe.OPTIONAL_HEADER
    dos = pe.DOS_HEADER.e_lfanew
    nt_off = dos + 4 + 20  # optional header start
    sect_off = nt_off + pe.FILE_HEADER.SizeOfOptionalHeader

    # Section layout: the packer merged everything into one .text block.
    # The original split survives in the optional header (BaseOfData).
    rsrc = pe.sections[1]
    sections = [
        (b".text", 0x1000, oh.BaseOfData - 0x1000, 0x60000020),
        (b".data", oh.BaseOfData, rsrc.VirtualAddress - oh.BaseOfData, 0xC0000040),
        (b".rsrc", rsrc.VirtualAddress, rsrc.Misc_VirtualSize, 0x40000040),
        (b".idata", imp_rva, len(blob), 0xC0000040),
    ]
    hdr_size = align(sect_off + 40 * len(sections), fa)
    if hdr_size > 0x1000:
        raise RuntimeError("headers do not fit")

    out = bytearray(image[:hdr_size])
    raw = []
    for name, rva, vsize, ch in sections:
        data = blob if name == b".idata" else image[rva:rva + vsize]
        raw.append((len(out), len(data)))
        out += data + bytes(align(len(data), fa) - len(data))
    for i, (name, rva, vsize, ch) in enumerate(sections):
        ptr, rsize = raw[i]
        struct.pack_into("<8sIIIIIIHHI", out, sect_off + 40 * i, name,
                         align(vsize, sa) if name != b".idata" else vsize,
                         rva, align(rsize, fa), ptr, 0, 0, 0, 0, ch)
    struct.pack_into("<H", out, dos + 4 + 2, len(sections))  # NumberOfSections
    struct.pack_into("<I", out, nt_off + 16, unp.oep - base)  # AddressOfEntryPoint
    struct.pack_into("<I", out, nt_off + 56, align(imp_rva + len(blob), sa))  # SizeOfImage
    struct.pack_into("<I", out, nt_off + 60, hdr_size)  # SizeOfHeaders
    struct.pack_into("<I", out, nt_off + 64, 0)  # CheckSum
    dd = nt_off + 96
    struct.pack_into("<II", out, dd + 8 * 1, imp_rva, 20 * (len(runs) + 1))
    iat_lo = min(r[1] for r in runs)
    iat_hi = max(r[1] + 4 * (len(r[2]) + 1) for r in runs)
    struct.pack_into("<II", out, dd + 8 * 12, iat_lo, iat_hi - iat_lo)
    with open(path, "wb") as f:
        f.write(out)


def referenced_runs(image, base, code_end_rva, runs):
    """Keep runs whose slots the original code addresses (abs32 operand).

    The stub resolves imports through the original lookup table as well, so
    the same names appear in a second, unreferenced copy; that copy and the
    stub's own IAT (above the original code) are dropped.
    """
    code = image[0x1000:code_end_rva]
    keep = []
    for run in runs:
        dll, rva, names = run
        slots = (struct.pack("<I", base + rva + 4 * i) for i in range(len(names)))
        if any(code.find(s) >= 0 for s in slots):
            keep.append(run)
    return keep


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    unp = Unpacker(sys.argv[1])
    image = unp.run()
    print("OEP %#x" % unp.oep)
    code_end = unp.pe.OPTIONAL_HEADER.BaseOfData
    runs = referenced_runs(image, unp.base, code_end,
                           group_thunks(find_iat(image, unp.apis)))
    total = sum(len(r[2]) for r in runs)
    print("imports: %d functions from %d runs" % (total, len(runs)))
    for dll, rva, names in runs:
        print("  %-16s IAT %#08x  %d" % (dll, unp.base + rva, len(names)))
    imported = {(r[0], n) for r in runs for n in r[2]}
    for d, n in sorted(set(unp.apis.values()) - imported):
        print("  resolved by stub only: %s!%s" % (d, n))
    write_pe(sys.argv[2], image, unp, runs)
    print("wrote", sys.argv[2])


if __name__ == "__main__":
    main()
