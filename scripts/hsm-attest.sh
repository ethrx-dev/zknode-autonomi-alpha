#!/bin/bash
# hsm-attest.sh — Generate periodic HSM attestation
# Called by systemd timer to prove node identity.
# Output: /var/lib/zymbit/attestation-latest.json

ATTEST_DIR="/home/zero-tech/zknode-autonomi-alpha/data/zymbit"
NODE_ADDR="0x63caa14c583dbfd5fe436fe6f9af6cb9e76a2095"

# Compute Merkle root of wiki pages as storage commitment
WIKI_ROOT="/home/zero-tech/zknode-autonomi-alpha/data/llm-wiki/wiki"
if [ -d "$WIKI_ROOT" ]; then
    MERKLE_ROOT=$(find "$WIKI_ROOT" -name '*.md' -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1)
else
    MERKLE_ROOT="0000000000000000000000000000000000000000000000000000000000000000"
fi

export MR="$MERKLE_ROOT"
export NA="$NODE_ADDR"
export AD="$ATTEST_DIR"
python3 << PYEOF
import zymkey, hashlib, json, sys, os

zk = zymkey.client
serial = zk.get_serial_number()
firmware = zk.get_firmware_version()
ecdsa_pub = zk.get_ecdsa_public_key()

merkle_root = os.environ.get('MR', '')
node_addr = os.environ.get('NA', '')
attest_dir = os.environ.get('AD', '/tmp')

message = f'zknode-storage:{merkle_root}:{node_addr}:{serial}'.encode()
signature = zk.sign_digest(hashlib.sha3_256(message), 0)

att = {
    'version': '1.0',
    'firmware': firmware,
    'serial': serial,
    'ecdsa_public_key': ecdsa_pub.hex(),
    'merkle_root': merkle_root,
    'node_address': node_addr,
    'message': message.decode(),
    'message_hash': hashlib.sha3_256(message).hexdigest(),
    'signature': signature.hex(),
    'proof_type': 'zymkey_ecdsa_secp256k1',
}

with open(f'{attest_dir}/attestation-latest.json', 'w') as f:
    json.dump(att, f, indent=2)

with open(f'{attest_dir}/attestation-sig.bin', 'wb') as f:
    f.write(signature)

print(f'Attestation: {serial[:16]}... merkleroot={merkle_root[:16]}...')

try:
    zk.verify_digest(hashlib.sha3_256(message), signature)
    print('Verification: PASSED')
except Exception as e:
    print(f'Verification: FAILED {e}')
    sys.exit(1)
PYEOF

echo "Attestation saved to ${ATTEST_DIR}/attestation-latest.json"
