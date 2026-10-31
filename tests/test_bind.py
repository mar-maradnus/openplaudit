"""Tests for the self-bind module (bind.py)."""

import re
from pathlib import Path

import pytest

from plaude.ble.bind import (
    build_creds,
    generate_keypair,
    load_sn_signature,
    normalize_historical_user_id,
    write_creds_file,
)
from plaude.ble.client import load_credentials

SN_SIG = "K7fCeAbJra8VoYlyBDDERbldG/1JGiwUInhVdnUFjsE5Iboe1x5ZTYZid82q"

def test_generate_keypair_returns_valid_pem():
    kp = generate_keypair()
    assert "-----BEGIN PUBLIC KEY-----" in kp["rsa_public_key"]
    assert "-----BEGIN PRIVATE KEY-----" in kp["rsa_private_key"]
    assert kp["rsa_public_key"].count("-----BEGIN") == 1
    assert kp["rsa_private_key"].count("-----BEGIN") == 1

def test_generate_keypair_distinct_keys():
    kp1 = generate_keypair()
    kp2 = generate_keypair()
    assert kp1["rsa_public_key"] != kp2["rsa_public_key"]
    assert kp1["rsa_private_key"] != kp2["rsa_private_key"]

def test_build_creds_preserves_sn_signature():
    kp = generate_keypair()
    creds = build_creds(SN_SIG, kp)
    assert creds["sn_signature"] == SN_SIG
    assert creds["rsa_public_key"] == kp["rsa_public_key"]
    assert creds["rsa_private_key"] == kp["rsa_private_key"]

def test_write_creds_file_roundtrip(tmp_path):
    kp = generate_keypair()
    creds = build_creds(SN_SIG, kp)
    p = tmp_path / "creds.md"
    write_creds_file(creds, p)
    assert p.exists()
    loaded = load_credentials(p)
    assert loaded["sn_signature"] == SN_SIG
    assert loaded["rsa_public_key"] == kp["rsa_public_key"]
    assert loaded["rsa_private_key"] == kp["rsa_private_key"]

def test_load_sn_signature(tmp_path):
    kp = generate_keypair()
    creds = build_creds(SN_SIG, kp)
    p = tmp_path / "creds.md"
    write_creds_file(creds, p)
    assert load_sn_signature(p) == SN_SIG

def test_load_sn_signature_missing(tmp_path):
    p = tmp_path / "bad.md"
    p.write_text("no signature here\n")
    with pytest.raises(ValueError):
        load_sn_signature(p)

def test_write_creds_file_uses_sn_signature_in_loaded_form(tmp_path):
    """The written file must be parseable by client.load_credentials."""
    kp = generate_keypair()
    creds = build_creds(SN_SIG, kp)
    p = tmp_path / "creds.md"
    write_creds_file(creds, p)
    text = p.read_text()
    assert re.search(r"sn_signature:\s*" + SN_SIG, text)

def test_normalize_historical_user_id_strips_prefix_and_dashes():
    assert normalize_historical_user_id("client_user_f3cd-3fd8-6033-4b10") == "f3cd3fd860334b10"
    assert normalize_historical_user_id("f3cd3fd860334b10b13eba1224e744e1") == "f3cd3fd860334b10b13eba1224e744e1"
    assert normalize_historical_user_id("client_user_f3cd3fd86033") == "f3cd3fd86033"

def test_normalize_historical_user_id_empty():
    assert normalize_historical_user_id("") == ""
