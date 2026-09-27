# Picks Arena Contracts

On-chain engine for **Picks Arena**: peer-to-peer contests of committed picks.

Gameplay lives **off-chain**. These contracts do not score lineups, match groups, or invent prize amounts. They:

1. take a signed entry and lock funds,
2. freeze a group membership,
3. verify that revealed picks match the commitment and that every referenced market is finalized,
4. apply an authority-signed result, and
5. move funds under hard bounds.

The machine **holds no tokens**. Custody is always a vault pair: entries in `EntryVault`, prizes in `PrizeTreasury`.

This audit package is only the Arena vault stack:

| Contract | Role |
|---|---|
| **ArenaMachine** | Upgradeable contest engine: placement, grouping, reveal, settlement, refunds, claims |
| **VaultFactory** | Deploys and catalogs immutable `(EntryVault, PrizeTreasury)` pairs |
| **EntryVault** | Entry custody: pull entries in, pay refunds / recycle consumed credit out |
| **PrizeTreasury** | Company prize float: no entry inflow; winners claim from here |
| **BaseVault** | Shared multi-token custody, whitelist, pause, per-token floor and per-tx cap |

`IEventMarketRegistry` is included as the **read interface** ArenaMachine uses for market finality. The registry implementation is out of scope.

---

## Who decides what

| Decision | Off-chain (authority / matchmaker) | On-chain (these contracts) |
|---|---|---|
| Which picks are legal, how they are scored, who won | Yes | No. The machine never computes a score. |
| Group size, mixed pick-counts, matching | Yes. `group_id` is derived off-chain. | Unique id, frozen `members_hash`, `max_group_size` ceiling. |
| Entry amount, token type, vault pair, prize ceiling | Proposed by the owner, **approved by the authority signature** | Dual signatures, nonce, active vault pair, `max_multiplier` cap. |
| When a lineup may be canceled | Window and eligibility are signed by the authority | Must still be ungrouped and `ACTIVE`. Full entry returned immediately. |
| When to refund (no group, commenced game, integrity) | Authority chooses the path and `reason_hash` | Status checks, full-entry amount only, signed reason. |
| Prize amounts | Server computes ranking / Perfect vs Top Score / ties | Win ≤ `entry × max_multiplier / 100`. Loss must be `0`. |
| Market results | Writers finalize markets on the registry | Reveal requires every pick’s market `is_settled`. |
| Moving funds | Nobody else can. | Machine is a **whitelisted operator** on the vaults. Vaults enforce token support, per-tx cap, and min-balance floor. |

Trust model: **rules are trusted; inputs and funds are not**. The authority can choose *who* won and *how much* (within the locked ceiling). It cannot place without the owner’s signature, cannot pay more than the locked multiplier, cannot mix entry money with prize money, and cannot drain a vault past its floor.

---

## Vault pair

```
                VaultFactory.createVaultPair()
                           │
                           ▼
              ┌────────────┴────────────┐
              │                         │
         EntryVault                PrizeTreasury
         (money in)                (money out)
              │                         │
   owner entries, refunds,      owner fund() of company
   consumed-credit recycle      capital; winner claim()
```

- Each pair is **append-only**. Addresses never change. `is_active` only gates **new** placements.
- A lineup stores `vault_pair_id` at placement and always settles/refunds against that pair.
- There is **no on-chain path** from `EntryVault` into `PrizeTreasury`. Prize float is funded by the owner from company capital (`BaseVault.fund`).
- `BaseVault` does not interpret coin vs credit. Token meaning lives in `ArenaMachine`.

`BaseVault` automated `payout()` (whitelisted machine only):

1. token must be `supported`,
2. amount ≤ `max_drain_per_tx` (0 = unlimited),
3. remaining balance ≥ `min_balance` (0 = disabled).

Owner `withdraw` / `recoverToken` are **not** rate-limited. An empty whitelist means nobody can move funds on the automated path.

---

## Lifecycle

### 1. Place a lineup

The owner signs the private picks commitment (`picks_hash`), size, token type, and nonce. The automated authority co-signs after off-chain checks (markets, multipliers, vault pair, ceiling). Anyone may submit; the owner pays no gas.

On success the machine:

- increments `wallet_nonce` **before** the token pull,
- pulls the entry into the pair’s `EntryVault` (`depositFor`),
- stores `ACTIVE` with `picks_hash`, `size`, `token_type`, `vault_pair_id`, and `max_multiplier`.

Picks stay hidden. `max_multiplier` is the **only** later prize bound and cannot be raised.

Token types:

| Type | Entry token | Prize token |
|---|---|---|
| 0 coin | coin | coin |
| 1 credit → coin | credit | coin |
| 2 credit → credit | credit | credit |

Credit-prize pairs are isolated from coin-prize pairs at configuration time.

### 2. Match into a group

The matchmaker builds a group off-chain and submits `assignGroup(group_id, sorted member ids)` with an authority signature.

The machine:

- requires a unused non-zero `group_id`,
- requires every member `ACTIVE` and ungrouped,
- requires strictly ascending ids,
- freezes `members_hash = keccak256(abi.encode(sorted ids))`.

Membership cannot change after this. Cancel is no longer allowed.

### 3. Reveal (layer 1) — `settleLineup`

When the referenced markets are finalized, the authority reveals `(picks, salt)`.

The machine checks:

- lineup is `ACTIVE` and **already grouped**,
- `keccak256(typehash, chain, machine, owner, picks, salt) == picks_hash`,
- market ids are strictly ascending,
- every market `is_settled` on the registry.

Pick-count limits are admission policy checked off-chain by the authority before signing a placement. Changing them does not restrict reveal or refund of already-committed lineups; the contract verifies the original picks commitment instead.

This only marks the lineup `SETTLED` (revealed). **No score, no `owed`, no transfer.**

### 4. Apply group results (layer 2) — `settleGroup`

The server computes scores and amounts off-chain, then submits the **full frozen roster** with parallel `amounts` and `outcomes` (`0` loss, `1` win).

The machine checks the authority signature, roster hash, and then:

- already-refunded members must be loss + amount `0` (placeholders; no second transfer),
- every other member must already be layer-1 `SETTLED`,
- a win records `owed` and reverts if `amount > entry × max_multiplier / 100`,
- a loss requires `amount == 0`.

Credit entries that are won or lost accrue `pending_credit_recycle` (consumed entry credit, recycled later). `settleGroup` makes **no external token calls**, so it cannot be reentered through a vault.

### 5. Claim a prize

`claim(lineup_id)` is pull-based. If `owed > 0` and the lineup is group-settled, the machine zeros `owed` and calls `PrizeTreasury.payout(owner, prize token, amount)`. Sending a transaction is not completion: `owed` is the source of truth.

Losses have `owed == 0` and nothing to claim.

---

## Refunds and cancel

All refunds are **full entry**. The authority passes `amount`; the machine reverts unless it equals the full entry. Partial refunds are not allowed. `reason_hash` is keccak256 of the off-chain reason key and is part of the signed payload and events.

Refunds are two-stage so a large group cannot run out of gas transferring every entry in one transaction:

1. **Mark** — status `REFUNDED`, `owed = amount`, emit `LineupRefunded`. No token transfer.
2. **Claim** — `claimRefund` / `batchClaimRefund` pulls refund `owed` from `EntryVault`. Prize wins use `claimPrize` / `batchClaimPrize` from `PrizeTreasury`.

| Path | When | Signatures | Effect |
|---|---|---|---|
| `cancelLineup` | Still ungrouped, owner wants out | Owner + authority | Status `CANCELED`, entry returned now |
| `batchRefundLineups` | One or many, ungrouped or members of an **active** group | Authority; each item carries `amount`, reveal + `market_results_hash` | Mark all `REFUNDED` + `owed`; members claim later |
| `refundGroup` | Whole locked group cannot settle safely | Authority; full roster + per-member `amounts` (0 if already refunded) | Mark remaining members `REFUNDED` + `owed`, group `REFUNDED`; members claim later |

`refundGroup` after every member is already `REFUNDED` (for example via batch) only closes the group. It does not pay twice.

Cancel requires `group_id == 0`. Grouped lineups use the batch or group path.

---

## Fund flow

```
Place:     owner  --approve-->  EntryVault
           machine --depositFor(owner, token, amount)--> EntryVault

Cancel:    machine --EntryVault.payout(owner, entry token, full entry)--> owner

Refund:    mark REFUNDED + owed, then claimRefund --EntryVault.payout(owner, entry token, owed)--> owner

Win claim: claimPrize --PrizeTreasury.payout(owner, prize token, owed)--> owner

Consumed
credit:    settleGroup accrues pending_credit_recycle
           authority --recycleConsumedCredit--> EntryVault.payout(credit vault, credit, accrued)
```

PrizeTreasury is replenished **off-chain** with `fund()`. Keep that float small; the min-balance floor is the automated drain guard.

---

## Signatures

User-facing placement and cancel are **gasless meta-transactions**: owner signature + automated authority signature. Settlement, grouping, and refunds are authority-only (plus a deadline).

Hashes bind `chainid` and `address(this)`. Placement uses a per-wallet nonce. Other actions use a deadline.

---

## What the machine will not do

- Score picks or re-run contest rules.
- Pay a win above the multiplier locked at placement.
- Pay a loss anything other than zero.
- Let a grouped lineup cancel.
- Move prize funds from entries, or entries from the prize float.
- Settle a group while any non-refunded member is still unrevealed or frozen.

Admin `freezeLineup` is an authority hold **before** the group settles. Unfreeze returns the lineup to `ACTIVE`, so a previous reveal must be repeated.

---

## Setup

```bash
pnpm install
forge build
forge test
```

```bash
forge test --match-path test/ArenaMachine.t.sol
forge test --match-path test/ArenaVaults.t.sol
forge test --match-path test/VaultFactory.t.sol
```
