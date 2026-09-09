# Disclaimer — Actively in Development (Proof of Concept)

> **This project is actively in development and testing. It is a proof of
> concept, not a finished product.**

## Status

- **Experimental**: the entire stack (post-quantum mixnet, agent mesh, AI
  companion, storage node, proving pipeline, dashboard) is under active
  development. Components change, break, and get replaced without notice.
- **Not production-ready**: no security audit has been performed. Configs,
  APIs, file layouts, and key material **will change in breaking ways**
  between commits.
- **Testnet only**: storage node operations target Autonomi testnet
  (Arbitrum Sepolia). Do **not** point this stack at mainnet, do not use
  wallet keys holding real funds, and do not route sensitive traffic through
  it.

## No warranty

The software is provided "as is", without warranty of any kind, express or
implied. The authors and contributors are not liable for any damages, data
loss, lost funds, or privacy failures arising from its use. See the license
(AGPL-3.0-only for source, CC-BY-SA-4.0 for documentation) for details.

## Operational warnings

- **Expect instability**: containers may crash-loop, mixnet epochs may skip,
  and the node may require re-provisioning at any time.
- **Key rotation is routine**: identity/key material may be invalidated at
  any point during development. Do not build anything on the assumption that
  a node identity persists. Rotation procedure: `config/mixnet/README.md`.
- **Hardware operations can be irreversible**: on SCM4/Zymbit hardware,
  production locking (`--production`) permanently binds security policies,
  and USB encryption (`--encrypt-usb`) destroys existing data. Read
  `docs/ZYMBIT_SETUP.md` and the safety rules in `AGENTS.md` before running
  any hardware provisioning step.
- **Repository history may be rewritten** during development. If a pull
  fails after an announced rewrite, re-clone rather than merging.

## Use at your own risk

If you deploy this, treat it as a lab experiment on hardware you own, on
networks you control, with keys you can afford to lose.
