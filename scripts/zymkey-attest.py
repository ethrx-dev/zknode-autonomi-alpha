#!/usr/bin/env python3
"""zknode-autonomi — Zymkey ZK Attestation
Generates a signed attestation binding the SCM4's zymkey identity
to the node's storage Merkle root, proving hardware-backed storage.
"""

import json
import sys
import hashlib

try:
    import zymkey
except ImportError:
    print("zymkey SDK not available (not on SCM4)", file=sys.stderr)
    sys.exit(1)


def validate_peer_params(merkle_root: str, node_address: str) -> None:
    if not isinstance(merkle_root, str) or len(merkle_root) != 64:
        raise ValueError(f"Invalid merkle_root: must be 64-char hex string, got {len(merkle_root)} chars")
    int(merkle_root, 16)
    if not isinstance(node_address, str) or not node_address.startswith("0x"):
        raise ValueError(f"Invalid node_address: must start with 0x, got {node_address!r}")
    if len(node_address) != 42:
        raise ValueError(f"Invalid node_address: must be 42 chars (0x + 40 hex), got {len(node_address)}")


def attest(merkle_root: str, node_address: str) -> dict:
    """Generate a zymkey-signed attestation over the storage commitment."""
    validate_peer_params(merkle_root, node_address)
    zk = zymkey.client

    firmware = zk.get_firmware_version()
    serial = zk.get_serial_number()
    ecdsa_pub = zk.get_ecdsa_public_key()

    message = f"zknode-storage:{merkle_root}:{node_address}:{serial}".encode()
    msg_hash_obj = hashlib.sha3_256(message)
    msg_hash = msg_hash_obj.digest()

    signature = zk.sign_digest(msg_hash_obj, 0)

    attestation = {
        "version": "1.0",
        "firmware": firmware,
        "serial": serial,
        "ecdsa_public_key": ecdsa_pub.hex(),
        "merkle_root": merkle_root,
        "node_address": node_address,
        "message": message.decode(),
        "message_hash": msg_hash.hex(),
        "signature": signature.hex(),
        "proof_type": "zymkey_ecdsa_secp256k1",
    }
    return attestation


def verify(att: dict) -> bool:
    """Verify a zymkey attestation (offline)."""
    zk = zymkey.client
    msg = att["message"].encode()
    msg_hash = hashlib.sha3_256(msg).digest()
    sig = bytes.fromhex(att["signature"])
    try:
        zk.verify_digest(msg_hash, sig)
        return True
    except Exception:
        return False


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Zymkey ZK Attestation")
    parser.add_argument("--merkle-root", required=True, help="Storage Merkle root")
    parser.add_argument("--node-address", default="0xNODE_ADDRESS_PLACEHOLDER",
                        help="Node rewards address")
    parser.add_argument("--verify", metavar="FILE", help="Verify attestation JSON file")

    args = parser.parse_args()

    if args.verify:
        with open(args.verify) as f:
            att = json.load(f)
        ok = verify(att)
        print(json.dumps({"verified": ok}, indent=2))
        sys.exit(0 if ok else 1)

    att = attest(args.merkle_root, args.node_address)
    print(json.dumps(att, indent=2))
