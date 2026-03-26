#!/usr/bin/env python3
import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def detect_binary_kind(data: bytes) -> str:
    if len(data) >= 4 and data[:4] == b"\x7fELF":
        return "linux"
    if len(data) >= 2 and data[:2] == b"MZ":
        return "windows"
    raise ValueError("Unsupported binary format (expected PE or ELF)")


def pe_text_ranges(data: bytes):
    if data[:2] != b"MZ":
        return []
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew:e_lfanew + 4] != b"PE\x00\x00":
        return []

    num_sections = struct.unpack_from("<H", data, e_lfanew + 6)[0]
    size_opt = struct.unpack_from("<H", data, e_lfanew + 20)[0]
    sec_table = e_lfanew + 24 + size_opt

    out = []
    for i in range(num_sections):
        o = sec_table + i * 40
        name = data[o:o + 8].split(b"\x00", 1)[0].decode("ascii", "ignore")
        raw_size, raw_ptr = struct.unpack_from("<II", data, o + 16)
        if name == ".text" and raw_size > 0:
            start = raw_ptr
            end = min(raw_ptr + raw_size, len(data))
            if start < end:
                out.append((start, end))
    return out


def elf_exec_ranges(data: bytes):
    if data[:4] != b"\x7fELF":
        return []

    ei_class = data[4]
    ei_data = data[5]
    if ei_data not in (1, 2):
        return []
    endian = "<" if ei_data == 1 else ">"

    out = []
    if ei_class == 2:  # ELF64
        e_phoff = struct.unpack_from(endian + "Q", data, 32)[0]
        e_phentsize = struct.unpack_from(endian + "H", data, 54)[0]
        e_phnum = struct.unpack_from(endian + "H", data, 56)[0]
        for i in range(e_phnum):
            o = e_phoff + i * e_phentsize
            if o + 56 > len(data):
                continue
            p_type, p_flags, p_offset, _p_vaddr, _p_paddr, p_filesz, _p_memsz, _p_align = struct.unpack_from(
                endian + "IIQQQQQQ", data, o
            )
            if p_type == 1 and (p_flags & 0x1) and p_filesz > 0:
                start = p_offset
                end = min(p_offset + p_filesz, len(data))
                if start < end:
                    out.append((start, end))
    elif ei_class == 1:  # ELF32
        e_phoff = struct.unpack_from(endian + "I", data, 28)[0]
        e_phentsize = struct.unpack_from(endian + "H", data, 42)[0]
        e_phnum = struct.unpack_from(endian + "H", data, 44)[0]
        for i in range(e_phnum):
            o = e_phoff + i * e_phentsize
            if o + 32 > len(data):
                continue
            p_type, p_offset, _p_vaddr, _p_paddr, p_filesz, _p_memsz, p_flags, _p_align = struct.unpack_from(
                endian + "IIIIIIII", data, o
            )
            if p_type == 1 and (p_flags & 0x1) and p_filesz > 0:
                start = p_offset
                end = min(p_offset + p_filesz, len(data))
                if start < end:
                    out.append((start, end))
    return out


def search_ranges_for_pattern(data: bytes, pattern, mask, ranges):
    n = len(pattern)
    anchor_idx = next((i for i, m in enumerate(mask) if m), None)
    if anchor_idx is None:
        raise ValueError("Pattern cannot be all wildcards")
    anchor_byte = pattern[anchor_idx]

    hits = []
    for start, end in ranges:
        i = start
        limit = end - n
        while i <= limit:
            pos = data.find(bytes([anchor_byte]), i + anchor_idx, end)
            if pos == -1:
                break
            candidate = pos - anchor_idx
            if candidate < start or candidate > limit:
                i = pos + 1
                continue

            ok = True
            for j in range(n):
                if mask[j] and data[candidate + j] != pattern[j]:
                    ok = False
                    break
            if ok:
                hits.append(candidate)
            i = pos + 1
    return hits


def parse_hex_pattern(pat: str):
    pattern = []
    mask = []
    for tok in pat.split():
        if tok == "??":
            pattern.append(0)
            mask.append(False)
        else:
            pattern.append(int(tok, 16))
            mask.append(True)
    return bytes(pattern), mask


def parse_hex_bytes(s: str):
    s = s.strip()
    if not s:
        return b""
    return bytes(int(tok, 16) for tok in s.split())


def load_spec(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if "patches" not in data or not isinstance(data["patches"], list):
        raise ValueError("Spec must contain a 'patches' list")
    return data


def patch_binary(input_path: Path, output_path: Path, spec_path: Path, report_path: Path | None):
    src = input_path.read_bytes()
    in_hash = sha256_bytes(src)

    kind = detect_binary_kind(src)
    spec = load_spec(spec_path)
    if spec.get("platform") and spec["platform"] != kind:
        raise ValueError(f"Spec platform '{spec['platform']}' does not match binary kind '{kind}'")

    ranges = pe_text_ranges(src) if kind == "windows" else elf_exec_ranges(src)
    if not ranges:
        ranges = [(0, len(src))]

    dst = bytearray(src)
    results = []
    failed = False

    for patch in spec["patches"]:
        name = patch["name"]
        pattern, mask = parse_hex_pattern(patch["pattern"])
        patch_offset = int(patch["patch_offset"])
        original = parse_hex_bytes(patch["original"])
        patched = parse_hex_bytes(patch["patched"])

        if len(original) != len(patched):
            raise ValueError(f"{name}: original and patched byte lengths differ")

        hits = search_ranges_for_pattern(src, pattern, mask, ranges)
        item = {
            "name": name,
            "match_count": len(hits),
            "status": "failed",
            "match_offsets": [f"0x{x:X}" for x in hits],
        }

        if len(hits) != 1:
            item["reason"] = "signature must match exactly once"
            failed = True
            results.append(item)
            continue

        match = hits[0]
        patch_at = match + patch_offset
        current = bytes(dst[patch_at:patch_at + len(original)])

        item["patch_offset"] = f"0x{patch_at:X}"
        item["current"] = current.hex(" ")

        if current == original:
            dst[patch_at:patch_at + len(patched)] = patched
            item["status"] = "patched"
        elif current == patched:
            item["status"] = "already_patched"
        else:
            item["status"] = "failed"
            item["reason"] = "bytes at patch site did not match original/patched forms"
            item["expected_original"] = original.hex(" ")
            item["expected_patched"] = patched.hex(" ")
            failed = True

        results.append(item)

    report = {
        "input": str(input_path),
        "output": str(output_path),
        "spec": str(spec_path),
        "kind": kind,
        "input_sha256": in_hash,
        "patches": results,
        "success": not failed,
    }

    if not failed:
        output_path.write_bytes(dst)
        report["output_sha256"] = sha256_file(output_path)

    if report_path is not None:
        report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    return report


def main():
    parser = argparse.ArgumentParser(description="Patch The Isle server binary with verified signatures")
    parser.add_argument("input", type=Path, help="Input binary path")
    parser.add_argument("output", type=Path, help="Output binary path")
    parser.add_argument("--spec", type=Path, default=None, help="Patch spec JSON path")
    parser.add_argument("--report", type=Path, default=None, help="Optional JSON report output path")
    args = parser.parse_args()

    input_data = args.input.read_bytes()
    kind = detect_binary_kind(input_data)

    if args.spec is None:
        default = "patches_windows.json" if kind == "windows" else "patches_linux.json"
        spec_path = Path(__file__).resolve().parent / default
    else:
        spec_path = args.spec

    report_path = args.report
    if report_path is None:
        report_path = args.output.with_suffix(args.output.suffix + ".patch_report.json")

    report = patch_binary(args.input, args.output, spec_path, report_path)
    print(json.dumps(report, indent=2))
    sys.exit(0 if report["success"] else 2)


if __name__ == "__main__":
    main()
