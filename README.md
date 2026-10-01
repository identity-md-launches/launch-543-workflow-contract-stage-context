# SevenDay staking contracts

An immutable staking vault for the fixed-supply SevenDay launch token. Users stake SEVEN, wait seven days to withdraw principal, and can claim separately funded SEVEN rewards at any time. Anyone can donate rewards. There is no administrator, fee, pause, upgrade, seizure, emergency withdrawal, or recovery function.

This contribution implements the contract stage: source, tests, ABI exports, and integration documentation. The separate manifest assignment generates `launch.json`; independent review and the services responsible for publication, attestation, admission, deployment, and the IPFS website follow this stage.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, optimizer 200 runs, Paris EVM, and `bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are disabled. All Solidity dependencies are ordinary vendored files; builds need no network once the pinned compiler is installed. Tests use no RPC, environment variables, wallet keys, or deployment scripts.

Dependencies: selected [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) sources and [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7). Their license files are preserved in `lib/`. File digests are in [docs/dependency-checksums.sha256](docs/dependency-checksums.sha256); there are no submodules or install steps. See [docs/verification.md](docs/verification.md) for executed checks and analyzer triage.

## Deployment parameters

| Order | Contract | Source | Nonpayable constructor |
| --- | --- | --- | --- |
| 1 | `LaunchToken` | `src/LaunchToken.sol` | No arguments |
| 2 | `StakingVault` | `src/StakingVault.sol` | `address token_` = `$token` |

`LaunchToken` is named **SevenDay**, symbol **SEVEN**, with 18 decimals. It mints exactly **1,000,000,000 tokens (10^27 minor units)** to its constructor caller, the factory in production. There are no later mint/burn or privileged functions. The approved brief supplied no name, symbol, or conflicting token economics; these names are project defaults. The vault constructor only stores the immutable token address and checks that it has code; it does not authenticate token behavior. The manifest and independent review must bind it to the accepted `LaunchToken` artifact.

There are no owner arguments or initialization calls. The constructors neither approve nor transfer tokens. The vault starts empty and unfunded; it does not receive any launch allocation automatically. Factory allocation, policy, signed artifact linkage, launch liquidity, and pool fees belong to the protocol services. Do not add pool fee logic or a pool guard to these contracts. Use the exact deployed addresses, chain ID, and pool key from the service handoff; none are invented here.

## Stake and lock behavior

- `stake(amount)` pulls a positive amount from the caller using their approval. The stake is recorded in token minor units, not shares. Every addition resets **that caller's entire position** to `block.timestamp + 7 days`; it cannot extend another wallet's lock.
- `unstake(amount)` returns a positive amount of the caller's principal at or after `unlockTime(caller)`. Partial withdrawals retain the existing unlock time. A full exit clears it. Withdrawal does not require claiming rewards or waiting for the reward period to end.
- `claim()` pays only the caller's accrued whole reward units, including during the lock and after a full exit. It does not reset the lock or compound. Claiming with no whole reward unit reverts.
- There is no transfer of staked positions, delegation, staking on behalf of someone else, or administrative withdrawal. Only successful additions can reset a lock.

## Reward funding and accounting

The brief left the reward asset, funding schedule, and additional-deposit lock policy open. This implementation chooses the same SEVEN token for principal and rewards, seven-day reward periods, and the wallet-wide lock reset described above. These are explicit review assumptions.

1. A funder approves the vault and calls `fundRewards(amount)`. This is an irrevocable donation with no refund right. A new period lasts exactly 604,800 seconds. At least 604,800 minor units of new plus queued funding are needed to produce a nonzero integer rate (0.000000000000604800 SEVEN).
2. During an active period, top-ups keep its original end time. The remaining scheduled budget, queued funds, and new donation are divided across its remaining seconds. This never lowers the previous rate or postpones existing rewards. Near the deadline, a donation may be emitted very quickly; funders should inspect `periodFinish` before approving a top-up.
3. Rewards accrue by elapsed seconds, pro rata to each wallet's current stake. Deposits, withdrawals, claims, and funding checkpoint the old weights first. New stakers receive no historical rewards. Stake continues earning after the principal unlocks while a funded reward period is active.
4. Rewards that elapse with no stakers are queued, not given retroactively to the first depositor. Anyone may call `restartRewards()` after the period ends if the queue funds a nonzero seven-day rate. Funding also incorporates this queue. No keeper is needed for normal accrual or claims; rescheduling idle funds requires a transaction.
5. Schedule division remainders are queued. The reward-per-token index uses 10^36 precision. Per-wallet fractions survive checkpoints, claims, and exits. Global index division rounds down; its small residual remains reserved forever and cannot be swept. A sub-minimum queue needs more funding before it can restart.

`rewardReserve` is accepted funding minus paid claims. `totalStaked` is the sum of wallet principal balances. With the supplied LaunchToken:

```text
vault token balance = totalStaked + rewardReserve + unsolicited transfers
all claimable rewards + future scheduled rewards + unallocated rewards <= rewardReserve
```

Only `fundRewards` adds newly received tokens to the reserve. Claims subtract from the reserve, and withdrawals subtract from principal; neither can spend the other category. Direct token transfers do not create stake, fund rewards, or affect weights. Such transfers and unrelated tokens are permanently stranded: there is deliberately no rescue authority. Do not send ETH or tokens directly to the vault.

The only supported production asset is the delivered, fee-free, non-rebasing LaunchToken. SafeERC20 checks transfer failures, exact incoming balance changes reject taxed transfers, and all state-changing vault entrypoints are guarded against reentrancy. These protections do not make arbitrary malicious or rebasing tokens safe.

## Frontend handoff and operations

[docs/integration.md](docs/integration.md) documents ABI calls for APR, total staked, wallet stake and rewards, stake/unstake/claim buttons, funding, and queued-reward maintenance. ABI JSON arrays are exported at [docs/abi/LaunchToken.json](docs/abi/LaunchToken.json) and [docs/abi/StakingVault.json](docs/abi/StakingVault.json).

APR is a simple annualized token rate, not a guaranteed return, APY, or a USD yield. Funding is voluntary and can run out. Chain timestamps define both locks and accrual; small timestamp variation near a boundary remains a chain trust assumption. There are no randomness, oracle, swap, external strategy, or off-chain custodian dependencies.

Before release, the independent contributor must review accepted source and the generated manifest together, including the `$token` binding, constructor compatibility, reward economics, and accounting. Deployment services publish and verify the actual artifacts and provide the chain/address handoff. Funders supply their own reward tokens after deployment; the frontend warns about donations and lock resets. No transactions or signatures are authorized or performed by this contribution. Successful local tests and static-analysis triage are not an independent audit or a guarantee of security.
