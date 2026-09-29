#!/usr/bin/env python3
"""Log in to the ObjectScale portal (port 443) and write a requests-compatible
session cookie header value to stdout or a file.

The portal login flow is:
  POST /startEncryptSession  -> returns a 30-char session key, sets cookies
  GET  /login                -> Authorization: ECS <base64>
       where <base64> is CryptoJS AES.encrypt("user:pass", sessionKey)
       == OpenSSL EVP_BytesToKey (MD5) + AES-256-CBC with "Salted__" header.

Usage: ui_session.py            -> prints the ECSUI_SESSION cookie value
       ui_session.py <file>     -> writes 'Cookie: ECSUI_SESSION=...' to file
"""
import base64
import hashlib
import http.client
import os
import ssl
import sys
from http.cookies import SimpleCookie

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend


def load_env():
    env_path = os.path.expanduser("~/.config/obs-demo/env")
    cfg = {}
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if line and "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                cfg[k] = v
    return cfg


def evp_bytes_to_key(passphrase: bytes, salt: bytes, key_len=32, iv_len=16):
    """OpenSSL EVP_BytesToKey with MD5 (what CryptoJS uses for passphrase AES)."""
    out = b""
    prev = b""
    while len(out) < key_len + iv_len:
        prev = hashlib.md5(prev + passphrase + salt).digest()
        out += prev
    return out[:key_len], out[key_len:key_len + iv_len]


def cryptojs_encrypt(message: str, passphrase: str) -> str:
    salt = os.urandom(8)
    key, iv = evp_bytes_to_key(passphrase.encode(), salt)
    data = message.encode()
    pad = 16 - len(data) % 16
    data += bytes([pad]) * pad
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
    enc = cipher.encryptor()
    ct = enc.update(data) + enc.finalize()
    return base64.b64encode(b"Salted__" + salt + ct).decode()


def main():
    cfg = load_env()
    host = cfg["OBS_MGMT_HOST"]
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    conn = http.client.HTTPSConnection(host, 443, context=ctx, timeout=30)
    conn.request("POST", "/startEncryptSession")
    resp = conn.getresponse()
    session_key = resp.read().decode().strip()
    cookies = SimpleCookie()
    for h, v in resp.getheaders():
        if h.lower() == "set-cookie":
            cookies.load(v)
    if not session_key:
        print("error: empty session key", file=sys.stderr)
        sys.exit(1)

    cookie_hdr = "; ".join(f"{k}={m.value}" for k, m in cookies.items())
    b64 = cryptojs_encrypt(f"{cfg['OBS_MGMT_USER']}:{cfg['OBS_MGMT_PASS']}", session_key)
    conn.request("GET", "/login", headers={
        "Authorization": f"ECS {b64}",
        "Cookie": cookie_hdr,
        "Accept": "application/json",
    })
    resp = conn.getresponse()
    body = resp.read().decode()
    for h, v in resp.getheaders():
        if h.lower() == "set-cookie":
            cookies.load(v)
    if resp.status != 200 or '"isSuccess":true' not in body.replace(" ", ""):
        print(f"error: login returned {resp.status}: {body[:300]}", file=sys.stderr)
        sys.exit(1)
    # Portal API calls authenticate with the authToken in X-SDS-AUTH-TOKEN
    # and the XSRF cookie echoed in X-XSRF-TOKEN.
    import json as _json
    auth_token = _json.loads(body)["data"]["authToken"]
    xsrf = cookies["XSRF-TOKEN"].value if "XSRF-TOKEN" in cookies else ""
    session = {"authToken": auth_token, "xsrf": xsrf}
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w") as f:
            _json.dump(session, f)
        os.chmod(sys.argv[1], 0o600)
    else:
        print(_json.dumps(session))


if __name__ == "__main__":
    main()
