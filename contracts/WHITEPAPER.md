# Yibble Vault Whitepaper — v2.0

**Date:** October 21, 2026
**Author:** Mason Weekley
**Chain:** Anvil local (EVM, chain ID 31337)
**Status:** Deployed, tested, no external audit

---

## 1. Abstract

Yibble is a three-token financial system:

- **ybUSD** — the institutional cash leg (the vault's underlying asset)
- **ypUSD** — the swap-input cash leg (exchanged 1:1 minus fee for ybUSD)
- **YIB** — the vault share (ERC-4626, 0.20% annual management fee)

The system has four deployed contracts. It is documented, tested (38 passing tests, 100% line and branch coverage on the vault), and reproducible from a fresh chain in one command. It has **not** been audited, has **no** legal opinion, and is **not** on any network other than local Anvil.

Every claim below is falsifiable against on-chain state.

---

## 2. The Three Tokens

### 2.1 ybUSD — Yibble USD

- **Contract:** `YibbleUSD.sol` — ERC-20, 6 decimals, owner-gated mint
- **Function:** institutional cash leg. This is the vault's underlying asset.
  On mainnet this slot will be USDC. Locally it is a mock that mirrors USDC's interface.
- **Who holds it:** anyone who has swapped ypUSD for ybUSD, or received a direct mint from the owner.
- **Transferable:** yes, standard ERC-20.
- **Production intent:** USDC. The vault accepts any ERC-20, so the swap to USDC is a constructor argument, not a code change.

### 2.2 ypUSD — Yipple USD

- **Contract:** `YipUSD.sol` — ERC-20, 6 decimals, owner-gated mint, user-callable burn
- **Function:** swap-input cash leg. Users who hold ypUSD exchange it for ybUSD through the `YibbleSwap` contract at 1:1 minus a fee (default 0.10%).
- **Who holds it:** anyone the owner has minted to. In the current design, the owner is the sole source of ypUSD.
- **Transferable:** yes, standard ERC-20.

### 2.3 YIB — Yibble Vault Share

- **Contract:** the vault itself (`YibbleVault.sol`) — ERC-4626, ERC-20 share
- **Function:** a proportional claim on the vault's assets.
  1 YIB = `convertToAssets(1e6)` ybUSD, net of accrued fees.
- **Who holds it:** depositors who have converted ybUSD into shares via `deposit()`.
- **Supply behavior:** grows on deposit, constant on fee accrual (fees reduce NAV per share, not supply).
- **Governance:** none. YIB is a pure economic instrument. Ownership of the vault contract is separate and held by the CEO.

### 2.4 How the Three Tokens Interact
*(Awaiting Section 3: The Architecture & Flow)*
