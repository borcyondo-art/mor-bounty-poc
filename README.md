# Morpheus Bug Bounty — Proof-of-Concept Tests

Foundry proof-of-concept tests for two verified findings against deployed
Morpheus smart contracts (mor.org/bug-bounty, v2). Read-only: the tests run
on mainnet forks and send no mainnet transactions. No privileged accounts
are impersonated — attacker/victim are ordinary addresses.

## Findings

### F1 — BuildersV4: subnet admin can permanently freeze staker funds (Medium)

- Target: `BuildersV4` at `0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9` on Base
- `editSubnet` has no upper bound and no timelock on
  `withdrawLockPeriodAfterDeposit`; `_validateSubnet` only checks the lock
  is `>= minimalWithdrawLockPeriod`. `withdraw` enforces
  `block.timestamp > lastDeposit + lock`, so an admin can raise the lock to
  `type(uint128).max` after users staked and freeze their principal forever
  while harvesting the yield on it. V3's `editPoolDeadline` guard was
  removed in V4 without a replacement.
- PoC: `test/BaseBuildersPoC.t.sol` — `test_adminCanPermanentlyFreezeStakerFunds`
  (fork pinned at Base block 58142937). Victim 10,000 MOR frozen (~$7,100);
  attacker harvests 2,897 MOR (~$2,057) over ~1 year; 2,977,182 MOR
  (~$2.1M) at risk across all subnets.

### F2 — DepositPool: self-referral earns ~16% extra MOR (Low)

- Target: `DepositPool (stETH)` at
  `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790` on Ethereum (same code in all
  five DepositPools)
- `stake()` accepts the staker's own address as `referrer_`; `_stake()`
  only substitutes a zero referrer and never checks `referrer_ != user_`,
  so one deposit earns both the 1% user referral bonus and the referrer
  tier reward (up to 15%).
- PoC: `test/EthCapitalPoC.t.sol` — contract `EthCapitalSelfReferralPoC`
  (fork pinned at Ethereum block 26426498). Attacker staking 100 stETH
  with self-referral earned 979.87 MOR vs 844.72 MOR for an identical
  honest staker (+15.99%); the honest staker is measurably diluted.

### Also tested, clean — LumerinDiamond

- `test/LumerinDiamondPoC.t.sol` (fork pinned at Base block 58145198):
  14 tests covering facet re-init, owner-only setters, full session
  lifecycle, dispute close, stranger close/claim, expired and wrong-chain
  approvals. No findings.

## Run

```sh
forge test
```

Dependencies (`forge-std`, the OpenZeppelin `IERC20`/`ECDSA` interfaces) are
vendored under `lib/`, and the fork RPCs are public read-only endpoints in
`foundry.toml`, so the suite runs with one command from a clean clone.
21 tests, all passing.
