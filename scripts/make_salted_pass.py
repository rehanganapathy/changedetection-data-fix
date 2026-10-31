#!/usr/bin/env python3
"""
Generate a SALTED_PASS value for changedetection.io.

changedetection.io checks the login password against base64(salt[32] + pbkdf2_sha256(password, salt, 100000)).
Setting it through the SALTED_PASS environment variable (instead of the Settings page) means:
  * the password lives in .env / your secret store, not only inside the datastore
  * nobody can remove it from the web UI
  * it survives container re-creation and datastore restores

Usage:
    python3 make_salted_pass.py              # prompts for the password
    python3 make_salted_pass.py 'my-secret'  # non-interactive
"""
import base64
import getpass
import hashlib
import os
import sys


def salted_pass(password: str) -> str:
    salt = os.urandom(32)
    key = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100000)
    return base64.b64encode(salt + key).decode("ascii")


if __name__ == "__main__":
    pw = sys.argv[1] if len(sys.argv) > 1 else getpass.getpass("New changedetection.io password: ")
    if len(pw) < 12:
        sys.exit("Use at least 12 characters.")
    print(salted_pass(pw))
