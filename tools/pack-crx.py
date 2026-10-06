#!/usr/bin/env python3
"""pack-crx.py: pack extension/ into a signed CRX3 plus the update XML Edge's force-install policy reads.

  python3 tools/pack-crx.py <extension dir> <signing key .pem> <out dir> <url of out dir>

Writes <out>/squelch-extension.crx and <out>/squelch-extension.xml and prints the extension ID. The ID comes
from the key, so the same key always gives the same ID (hnaihkcljcmkkkoblpgffnkdneaneama for ForIT's key).
Python stdlib plus the openssl CLI only, so it runs on a stock Mac with the Command Line Tools.
"""
import hashlib, io, json, os, struct, subprocess, sys, zipfile

ext_dir, key, out_dir, base_url = sys.argv[1:5]

def varint(n):
    b = bytearray()
    while True:
        byte, n = n & 0x7F, n >> 7
        b.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(b)

def field(num, data):  # protobuf length-delimited field
    return varint(num << 3 | 2) + varint(len(data)) + data

# Zip the extension with fixed timestamps so the same sources give the same bytes.
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
    for name in sorted(os.listdir(ext_dir)):
        path = os.path.join(ext_dir, name)
        if os.path.isfile(path) and not name.startswith("."):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, open(path, "rb").read())
archive = buf.getvalue()

pub = subprocess.run(["openssl", "rsa", "-in", key, "-pubout", "-outform", "DER"],
                     capture_output=True, check=True).stdout
crx_id = hashlib.sha256(pub).digest()[:16]
ext_id = "".join(chr(ord("a") + int(c, 16)) for c in crx_id.hex())

signed_data = field(1, crx_id)  # SignedData { crx_id }
to_sign = b"CRX3 SignedData\x00" + struct.pack("<I", len(signed_data)) + signed_data + archive
sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=to_sign,
                     capture_output=True, check=True).stdout
# CrxFileHeader { sha256_with_rsa = 2: AsymmetricKeyProof { public_key = 1, signature = 2 }, signed_header_data = 10000 }
header = field(2, field(1, pub) + field(2, sig)) + field(10000, signed_data)

version = json.load(open(os.path.join(ext_dir, "manifest.json")))["version"]
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "squelch-extension.crx"), "wb") as f:
    f.write(b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive)
with open(os.path.join(out_dir, "squelch-extension.xml"), "w") as f:
    f.write("<?xml version='1.0' encoding='UTF-8'?>\n"
            "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>\n"
            f"  <app appid='{ext_id}'>\n"
            f"    <updatecheck codebase='{base_url}/squelch-extension.crx' version='{version}' />\n"
            "  </app>\n"
            "</gupdate>\n")
print(f"packed extension {ext_id} {version}")
