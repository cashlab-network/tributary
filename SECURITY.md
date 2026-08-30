# Security Policy

## Status

Tributary is **pre-audit software**. It runs on the **Flare Coston2 testnet only**
with throwaway keys and faucet tokens — **no real user funds are at risk**, and
nothing is deployed to mainnet. A professional third-party audit is the required
gate before any real value moves. Until then, treat this code as a reference
implementation, not a production system.

The contracts have had internal adversarial security review; findings and known
limitations are tracked in `HOW-IT-WORKS.md` (the gaps register) and `TESTING.md`.

## Reporting a vulnerability

If you find a security issue, please report it **privately** — do not open a
public issue or PR, and do not disclose it publicly until it has been addressed.

- Email: **hello@cashlab.network** (subject line: `SECURITY — Tributary`)

Please include: the affected contract/function, a description of the issue, and a
proof-of-concept or reproduction steps if you have one. We'll acknowledge receipt
and work with you on a fix and coordinated disclosure.

## Scope

In scope: the Solidity contracts in `src/`.

Out of scope: the `app/` frontend, `script/` and `keeper/` tooling, the vendored
`.claude/skills`, testnet deployments (no real value), and issues that require
compromising a user's own keys.

## Bug bounty

There is no paid bug bounty yet (pre-audit, testnet). Good-faith reports are
genuinely appreciated and will be credited (with your permission) once a fix
ships.
