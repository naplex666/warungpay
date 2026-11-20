# WarungPay

**tUSD8 checkout for small shops (warung) on Aevum testnet.**
Aevum Builder Challenge #1 — Invoice Payments track — DoraHacks.

Merchant creates an invoice → buyer pays in tUSD8 → the contract splits
automatically: **90% straight to the merchant, 10% into the merchant's
on-chain savings pot** (pull-payment withdrawal). Cashiers get session keys:
capped per invoice, time-limited, instantly revocable.

## Network

- Aevum testnet — chain ID **44005**, RPC `https://rpc-test.qday.info`
- tUSD8: `0x456569838f1d43009A91ebA4263147Afd7233483` (ERC20, 6 decimals)
- Explorer: https://explorer-test.qday.info
- Faucet: https://faucet.qday.info (tQDAY gas + tUSD8)

## Contract

`src/WarungPay.sol` (Solidity ^0.8.24, Foundry, OpenZeppelin ReentrancyGuard).

| Function | Who | What |
|---|---|---|
| `registerMerchant()` | anyone | Register as a merchant (default split 90/10) |
| `createInvoice(amount, note, expiry)` | merchant | Create an invoice |
| `createInvoiceFor(merchant, amount, note, expiry)` | cashier | Create an invoice for a merchant (enforces key cap + expiry + revoke) |
| `payInvoice(id)` | buyer | Pay in tUSD8 (needs ERC20 approval); split happens automatically |
| `savingsOf(merchant)` | anyone | Savings pot balance |
| `withdrawSavings(amount)` | merchant | Pull-payment withdrawal from the savings pot |
| `grantCashier(cashier, cap, expiry)` | merchant | Issue a session key |
| `revokeCashier(cashier)` | merchant | Revoke a session key instantly |
| `setSplit(savingsBps)` | merchant | Savings share, 0–50% (default 10%) |
| `setDailyCap(cap)` | merchant | Max tUSD8 received per UTC day (0 = unlimited) |

Security: `ReentrancyGuard` on payments/withdrawals, checks-effects-interactions,
pull-payment savings, expiry + cap + revoke checks, split bounds (0–50%),
daily receive cap.

Events (on-chain receipts): `MerchantRegistered`, `InvoiceCreated`,
`InvoicePaid`, `SavingsWithdrawn`, `CashierGranted`, `CashierRevoked`,
`SplitUpdated`, `DailyCapUpdated`.

## Development

```bash
forge build
forge test        # 27 tests: lifecycle, split math, expiry, cap, revoke, daily cap
```

## Deploy (Aevum testnet)

Deployer needs tQDAY (gas) + tUSD8 from the faucet first.

```bash
./deploy.sh   # reads the deployer key from hidden_files/deployer.json (never printed/committed)
```

Deployed contract address: **TBD** (deploy pending faucet claim — deployer wallet
currently empty). Update this README after deploy.

## Status

- [x] Contract + 27 tests (all passing)
- [x] Deploy script (`script/Deploy.s.sol`, `deploy.sh`)
- [ ] Deployed + verified on explorer-test.qday.info (blocked: faucet claim)
- [ ] Live demo (GitHub Pages)
- [ ] Video demo (on-screen text only, no voice-over)
- [ ] DoraHacks submission (deadline 11 Dec 2026 15:00 WIB)
