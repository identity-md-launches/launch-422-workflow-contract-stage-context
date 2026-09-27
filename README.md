# Agent Arcade — contracts

Sepolia-only prototype: the **Workflow Demo (WFD)** launch token and the **AgentArcade** mystery-pack game.
This repository is the source-producing contribution of the contract stage. It contains the contracts,
their tests, exported ABIs and this document. It does not contain `launch.json` (written by the manifest
assignment), the Uniswap v4 pool, the Merkle claim distributor or the website; those are produced by the
ProjectFactory and by later services.

| Contract | File | Manifest role |
| --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | the launch token (`$token`) |
| `AgentArcade` | `src/AgentArcade.sol` | the single application contract |

ABIs: `docs/abi/LaunchToken.json`, `docs/abi/AgentArcade.json`.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`, no `ffi`, no
filesystem permissions. The only dependency is `forge-std` v1.9.7, vendored as plain files under `lib/`.
Tests read no environment variables and pass in any order and in parallel.

## LaunchToken (WFD)

Fixed-supply ERC-20, name `Workflow Demo`, symbol `WFD`, 18 decimals. The constructor takes no arguments
and mints the entire supply to `msg.sender` (the factory). There is no owner, mint, burn, pause,
blocklist, fee, hook or upgrade path, and the runtime contains no `DELEGATECALL`, `CALLCODE` or
`SELFDESTRUCT`.

**Supply discrepancy (review finding).** The approved brief says "1,000,000 supply". The launch policy
that admits a token requires exactly 1,000,000,000 tokens (10^27 minor units) minted to the factory, and
the factory rejects any other supply (`SupplyMismatch`). The policy figure is implemented. If the
sponsor wants the brief's figure, the policy must change first; the contract cannot satisfy both.

**Distribution is not in this repository.** The brief's allocation (100% equally per actively enrolled
Identity MD NFT in collection `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d`, snapshot at a finalized
block, deterministic rounding, aggregation to owners, cross-chain contract-wallet resolution, immutable
fixed-recipient Merkle claims without expiry) is executed by the protocol `MerkleDistributor` that the
factory deploys, fed by the services' snapshot. The factory splits the supply per policy v5: liquidity,
the claim tree, 2% launch contributors, 8% recent accepted work. Nothing in this repository can mint,
so initial liquidity and the claim tree can only be funded from that one-time supply, and prizes can
only be funded from WFD the sponsor already holds.

## AgentArcade

One sponsor funds finite, immutable epochs of 2–64 collectible packs, each fully backed by WFD held in
the contract. A draw buys one uniformly random remaining pack of an epoch. The winner receives an
ERC-721 pack and may keep it, transfer it, or redeem its backing to whoever owns it at that time.

### Roles and powers

| Role | Set by | Powers |
| --- | --- | --- |
| `sponsor` | constructor (`$owner`) | `createEpoch`, `sweepEpoch` of closed epochs, `setPaused`, withdraw the sponsor share |
| `feeRecipient` | constructor | withdraw accumulated fees only |
| VRF coordinator | constructor | call `rawFulfillRandomWords` |
| anyone | — | `draw`, `settle`, `deliver`, `redeem` (own packs), `withdrawPayments` (own credit) |

All configuration is immutable. There is no ownership transfer, no upgrade, no initializer, no
`msg.sender` use in the constructor, and no way for anyone (sponsor included) to move backing except
through a pack redemption. **Pause stops new draws only**: settlement, delivery, redemption, withdrawals
and epoch creation continue while paused.

### Epochs

* `createEpoch(uint256[] backings)`: 2–64 packs, every backing > 0, at least two distinct values. Pulls
  the sum from the sponsor via `transferFrom`. Epochs cannot be edited, topped up or closed manually.
* Draws stop automatically when fewer than two distinct backing values remain among unsold packs
  (a draw whose outcome is certain is not a mystery). Six distinct values therefore run down to one pack;
  two values may stop with several identical packs left.
* `sweepEpoch(epochId)`: once draws have stopped and no draw on that epoch is pending, the sponsor
  receives the unsold packs as NFTs. Backing stays attached; the sponsor redeems like any holder.
* An open epoch nobody draws from keeps its backing locked until variety is exhausted. That is the cost
  of the brief's "finite immutable epochs" and is the sponsor's decision at funding time.

### Pricing, odds, fee

For remaining backing `B` and remaining pack count `N`:

```
price          = ceil(B * 10000 / (N * 9500))
fee            = floor(price * 500 / 10000)         -> feeRecipient
sponsorShare   = price - fee                        -> sponsor
expectedPayout = B / N                              (95% of price, up to rounding)
odds per pack  = 1 / N                              (exact per-value odds: count(value) / N)
```

`quote(epochId)` returns all of the above plus the inventory `version` and whether draws are open.
`remainingPackBackings(epochId)` lists every unsold backing so the site can show exact odds per value.
Fees and sponsor share are credited as withdrawable balances at draw time and pulled with
`withdrawPayments`; nothing is pushed, so no recipient can block a draw.

### Draw lifecycle

1. `draw(epochId, expectedVersion, maxCost)` — reverts if paused, if another draw is pending, if the
   epoch is closed or unknown, if `expectedVersion` is not the epoch's current inventory version, or if
   the price exceeds `maxCost`. Pulls the price in WFD, credits fee and sponsor share, requests one
   random word from Chainlink VRF v2.5. **Once this returns the draw is accepted: no cancellation, no
   reroll, no refund.**
2. `rawFulfillRandomWords` — coordinator only. Stores the word and flips the draw to `Fulfilled`.
   Duplicate, unknown or empty fulfilments are ignored rather than reverted so a stray callback cannot
   burn the request.
3. `settle(drawId)` — permissionless. Picks index `randomness mod N`, removes the pack by swap-and-pop,
   bumps the inventory version, applies the variety rule, frees the pending slot.
4. `deliver(drawId)` — permissionless. Mints the pack to the buyer with a plain mint (no
   `onERC721Received` call), so a contract buyer cannot stall the arcade. A buyer that is a contract
   without ERC-721 support still receives the pack; recovering it is their problem.
5. `redeem(packId)` — current owner only. Burns the pack and transfers its backing to the owner.

Only one draw can be pending across all epochs. The next draw may start as soon as the previous one is
settled, before it is delivered.

### Randomness and provider delays

Randomness is Chainlink VRF v2.5 (subscription method). The consumer authenticates the coordinator by
address; the coordinator verifies the VRF proof on chain. Fulfilment on Sepolia typically takes the
configured confirmations (minimum 3 blocks) plus node latency, usually under a few minutes, and the site
must show a draw as pending with its `requestedAt` timestamp until `RandomnessReceived` is emitted.

**Stuck-request risk (review finding).** Because the brief forbids cancellation and rerolls after
acceptance, a request the coordinator never fulfils (unfunded subscription, consumer not registered,
gas lane withdrawn) stalls every future draw permanently: the paid price is already owed to sponsor and
fee recipient, the pending pack stays unsold, and unsold packs of that epoch can never be swept.
Mitigation is purely operational (below). A timeout path would violate the brief and was deliberately
not added; the independent review should confirm that trade-off.

The `MockVRFCoordinator` under `test/mocks/` and the `LocalDemo` script demonstrate control flow only.
Anyone who can call the mock's `fulfill` chooses the outcome; it is not randomness and must never be
deployed publicly.

### Accounting invariants

`totalLiabilities() = unsoldBacking + reservedBacking + mintedBacking + totalWithdrawable` and the
contract's WFD balance always equals it (tested by unit tests and by a handler-driven invariant suite).
`surplus()` reports WFD sent to the contract by mistake; nobody can withdraw it. Reentrancy is guarded
on every state-changing entry point and all external calls come after state updates; WFD has no
transfer hooks, and the only callback path (`safeTransferFrom`) runs after ownership has moved.

Identity MD NFTs are never referenced or wagered by these contracts.

## Deployment parameters (for the manifest assignment)

`launch.json` uses kind `evm_project`, names `LaunchToken` as the token, and lists one application
contract, identifier `AgentArcade`, constructor arguments in this order:

| # | Type | Parameter | Value |
| --- | --- | --- | --- |
| 1 | address | `token_` | `$token` |
| 2 | address | `sponsor_` | `$owner` |
| 3 | address | `feeRecipient_` | `$owner`, or a separately agreed fee treasury |
| 4 | address | `coordinator_` | Sepolia VRF v2.5 coordinator `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` |
| 5 | uint256 | `subscriptionId_` | the operator's VRF v2.5 subscription id (non-zero; **must be created before the manifest is written**) |
| 6 | bytes32 | `keyHash_` | Sepolia 500 gwei lane `0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae` |
| 7 | uint32 | `callbackGasLimit_` | `150000` (the callback only stores one word; measured well under 100k) |
| 8 | uint16 | `requestConfirmations_` | `3` (Sepolia minimum; maximum 200) |
| 9 | bool | `nativePayment_` | `true` to pay VRF in Sepolia ETH, `false` for testnet LINK |

The constructor is nonpayable, makes no external calls and does not touch WFD, so the factory's supply
check is unaffected. The runtime is about 13.6 KB (EIP-170 limit 24,576) and contains no
`DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. Both protected floor tests (token and project) were run
locally against this bytecode with representative environment values and pass.

**Unresolved deployment choices** (the manifest assignment or operator must decide):

* the VRF subscription id — no subscription exists yet, and creating one needs a funded wallet, which
  this assignment does not control;
* `nativePayment_` — ETH or LINK funding of the subscription;
* whether `feeRecipient_` is the sponsor (`$owner`) or a separate address; a literal address would be a
  privileged beneficiary and must be justified in review.

## Operational responsibilities after deployment

1. Fund the VRF subscription (ETH or LINK to match `nativePayment_`) and add the deployed `AgentArcade`
   address as a consumer. Do this **before** the first `draw`; a request from an unregistered consumer
   is rejected by the coordinator and the draw transaction reverts (no funds move), but a registered
   consumer on an unfunded subscription produces the stuck request described above.
2. Keep the subscription funded for the life of the arcade. Monitor `DrawRequested` without a matching
   `RandomnessReceived` and top up immediately; VRF v2.5 fulfils outstanding requests once balance is
   restored.
3. The sponsor must hold WFD before creating an epoch, obtained through the Merkle claim or the market.
   Claim reserves and liquidity are never a prize source; nothing here can reach them.
4. Approve the arcade for the epoch total, then `createEpoch`. Publish the backing list; the site's
   Vault and Transparency views read `remainingPackBackings`, `quote`, `epochInfo`, `totalLiabilities`
   and `surplus`.
5. Run (or let anyone run) `settle` and `deliver` after each fulfilment; the site should offer both
   buttons to any wallet.
6. Use `setPaused(true)` only to stop new draws (for example while a subscription is being refilled).

## Market, liquidity and claims (context, not in this repository)

The ProjectFactory creates the Uniswap v4 pool paired against native ETH (fee 3000, tick spacing 60,
**no hook**, so there are no hook permissions to document) and seeds it with WFD only; the effective
opening price comes from the pinned policy (20 ETH opening FDV under policy v5). There is no burn route
in WFD or in the pool configuration. Liquidity, the Merkle claim tree and arcade prizes live in three
separate contracts, and none of them can draw on another. Verified POOL4 source and Sepolia dependency
addresses are the services' publication responsibility.

## Scope and honesty notes

* Sepolia only. Nothing here is fit for mainnet or real-value wagering, and the tests are not an audit.
  An independent adversarial review is a required next step before any funded use.
* This assignment did not touch a wallet key, broadcast a transaction or create a VRF subscription.
* `script/LocalDemo.s.sol` is labelled **LOCAL DEMO ONLY**; it deploys the mock coordinator and must not
  be run against a public network.
