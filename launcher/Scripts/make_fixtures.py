#!/usr/bin/env python3
"""Generate tiny PE images for MGCoreTests (no compiler needed).

Each image has valid DOS/PE/optional headers, one section holding an import
directory (and optionally a delay-import directory) and the DLL name strings.
There is no code; the files exist only to exercise the import-table parser.

Usage: python3 Scripts/make_fixtures.py   (writes Tests/MGCoreTests/Fixtures/)
"""
import os
import struct

OUT = os.path.join(os.path.dirname(__file__), "..", "Tests", "MGCoreTests", "Fixtures")
SECT_RVA = 0x1000
FILE_ALIGN = 0x200


def pe(imports, delay=(), is64=True, old_style_delay=False):
    image_base = 0x140000000 if is64 else 0x400000
    # Section body layout: import descriptors, delay descriptors, then strings.
    n_imp = len(imports)
    n_del = len(delay)
    imp_off = 0
    del_off = imp_off + 20 * (n_imp + 1)
    thunk = 8 if is64 else 4
    # Every DLL gets a two-slot thunk array (one import by name, then a terminator), used as
    # both lookup and address table, plus a hint/name entry "x".
    thunk_off = del_off + (32 * (n_del + 1) if n_del else 0)
    n_all = n_imp + n_del
    hint_off = thunk_off + 2 * thunk * n_all
    str_off = hint_off + 4
    body = bytearray()
    names = {}
    strings = bytearray()
    for n in list(imports) + list(delay):
        if n not in names:
            names[n] = str_off + len(strings)
            strings += n.encode() + b"\0"

    def thunks(i):
        return SECT_RVA + thunk_off + 2 * thunk * i

    for i, n in enumerate(imports):
        # OriginalFirstThunk, TimeDateStamp, ForwarderChain, Name, FirstThunk
        body += struct.pack("<IIIII", thunks(i), 0, 0, SECT_RVA + names[n], thunks(i))
    body += b"\0" * 20
    if n_del:
        for j, n in enumerate(delay):
            t = thunks(n_imp + j)
            rva = SECT_RVA + names[n]
            if old_style_delay:
                va = lambda r: image_base + r
                body += struct.pack("<IIIIIIII", 0, va(rva), 0, va(t), va(t), 0, 0, 0)
            else:
                body += struct.pack("<IIIIIIII", 1, rva, 0, t, t, 0, 0, 0)
        body += b"\0" * 32
    for i in range(n_all):
        body += struct.pack("<Q" if is64 else "<I", SECT_RVA + hint_off) + b"\0" * thunk
    body += b"\0\0x\0"
    body += strings
    raw_size = (len(body) + FILE_ALIGN - 1) // FILE_ALIGN * FILE_ALIGN
    body += b"\0" * (raw_size - len(body))

    opt_size = 240 if is64 else 224
    pe_off = 0x40
    headers_size = FILE_ALIGN

    dos = bytearray(0x40)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, pe_off)

    coff = struct.pack("<HHIIIHH", 0x8664 if is64 else 0x14C, 1, 0, 0, 0, opt_size, 0x22)

    opt = bytearray(opt_size)
    if is64:
        struct.pack_into("<H", opt, 0, 0x20B)
        struct.pack_into("<Q", opt, 24, image_base)
        dd = 112
        struct.pack_into("<I", opt, 108, 16)
    else:
        struct.pack_into("<H", opt, 0, 0x10B)
        struct.pack_into("<I", opt, 28, image_base)
        dd = 96
        struct.pack_into("<I", opt, 92, 16)
    struct.pack_into("<II", opt, 32, 0x1000, FILE_ALIGN)  # SectionAlignment, FileAlignment
    struct.pack_into("<I", opt, 56, SECT_RVA + 0x1000)    # SizeOfImage
    struct.pack_into("<I", opt, 60, headers_size)         # SizeOfHeaders
    struct.pack_into("<H", opt, 68, 3)                    # Subsystem: console
    if n_imp:
        struct.pack_into("<II", opt, dd + 8 * 1, SECT_RVA + imp_off, 20 * (n_imp + 1))
    if n_del:
        struct.pack_into("<II", opt, dd + 8 * 13, SECT_RVA + del_off, 32 * (n_del + 1))

    sect = bytearray(40)
    sect[0:6] = b".idata"
    struct.pack_into("<IIII", sect, 8, len(body), SECT_RVA, raw_size, headers_size)
    struct.pack_into("<I", sect, 36, 0xC0000040)

    hdr = dos + b"PE\0\0" + coff + opt + sect
    hdr += b"\0" * (headers_size - len(hdr))
    return bytes(hdr + body)


FIXTURES = {
    "dx12.exe": pe(["KERNEL32.dll", "d3d12.dll", "dxgi.dll"]),
    "dx11.exe": pe(["KERNEL32.dll", "USER32.dll", "D3D11.dll", "dxgi.dll"]),
    "dx10.exe": pe(["kernel32.dll", "d3d10.dll"], is64=False),
    "dx9.exe": pe(["kernel32.dll", "d3d9.dll"], is64=False),
    "dx8.exe": pe(["kernel32.dll", "d3d8.dll"], is64=False),
    "ddraw.exe": pe(["kernel32.dll", "ddraw.dll"], is64=False),
    "delay11.exe": pe(["kernel32.dll"], delay=["d3d11.dll"]),
    "delay9-old.exe": pe(["kernel32.dll"], delay=["d3d9.dll"], is64=False, old_style_delay=True),
    "plain.exe": pe(["kernel32.dll", "user32.dll"]),
    "noimports.exe": pe([]),
    # Engine layout: the exe imports nothing graphical, a DLL next to it does.
    os.path.join("engine", "game.exe"): pe(["kernel32.dll", "engine2.dll"]),
    os.path.join("engine", "engine2.dll"): pe(["kernel32.dll"]),
    os.path.join("engine", "rendersystemdx11.dll"): pe(["kernel32.dll", "d3d11.dll", "dxgi.dll"]),
}


def main():
    for name, data in FIXTURES.items():
        path = os.path.join(OUT, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    # Damaged inputs.
    good = FIXTURES["dx11.exe"]
    with open(os.path.join(OUT, "truncated.exe"), "wb") as f:
        f.write(good[:0x60])
    with open(os.path.join(OUT, "notpe.txt"), "wb") as f:
        f.write(b"MZ but not really a PE file" + b"\0" * 64)
    bad = bytearray(good)
    # Import directory points past the end of the file: parser must not crash.
    struct.pack_into("<I", bad, 0x40 + 4 + 20 + 112 + 8, 0x7FFF0000)
    with open(os.path.join(OUT, "badimportrva.exe"), "wb") as f:
        f.write(bytes(bad))


if __name__ == "__main__":
    main()
