# ABI and frontend integration

Read deployed addresses and chain ID from the deployment service's final handoff. Use `docs/abi/LaunchToken.json` and `docs/abi/StakingVault.json` as ABI arrays. Both constructors are nonpayable; the vault's sole argument is the accepted launch token address. No post-deployment initialization or owner transaction is required.

To regenerate the checked-in ABI exports after an accepted source change:

```sh
forge inspect LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect StakingVault abi --json > docs/abi/StakingVault.json
```

## Dashboard reads

Read related values at the same block, using a deployment-chain provider. Treat integer amounts as big integers; format SEVEN with 18 decimals. Refresh after receipts and new blocks. Block timestamps, rather than a browser clock, decide withdrawal eligibility.

| Display | Call | Interpretation |
| --- | --- | --- |
| Token | `token()` on vault; `name()`, `symbol()`, `decimals()` on token | Verify token address against handoff |
| Total staked | `totalStaked()` | Principal only; do not use raw vault token balance |
| Current APR | `aprBps()` | Divide by 100 for percent, e.g. 1234 means 12.34% |
| Connected wallet stake | `balanceOf(wallet)` on vault | Withdrawable amount after unlock |
| Available rewards | `earned(wallet)` | Current whole minor units; do not display only cached `rewards(wallet)` |
| Lock ends | `unlockTime(wallet)` | Unix timestamp; zero for an empty position |
| Wallet token balance | `balanceOf(wallet)` on token | Spendable SEVEN outside the vault |
| Approval | `allowance(wallet, vault)` on token | Spend ceiling for stake or reward donation |
| Current reward speed | `rewardRate()` and `periodFinish()` | Rate is historical after finish; effective rate is zero then |
| Idle funding | `unallocatedRewards()` | Live queue including elapsed empty-vault emissions |
| Reward reserve | `rewardReserve()` | Includes earned, future, queued, and rounding residual funds |

`aprBps = floor(rewardRate * 31,536,000 * 10,000 / totalStaked)` during an active period with positive total stake; otherwise zero. The display assumes unchanged rate/stake for a year even though the current period lasts at most seven days. Show the current period end alongside APR. It excludes compounding and price appreciation.

## User actions

| Button | Transaction | Preconditions and confirmation text |
| --- | --- | --- |
| Stake | Token `approve(vault, amount)` if needed, then vault `stake(amount)` | Positive amount within wallet balance; approve exact amount. **Adding stake locks the entire position for another seven days.** |
| Unstake | Vault `unstake(amount)` | Positive amount no greater than wallet stake and chain timestamp at least unlock time. Rewards remain separately claimable. |
| Claim | Vault `claim()` | `earned(wallet) > 0`. Claiming never extends the lock. Return value is the paid amount. |
| Fund rewards | Token approval, then vault `fundRewards(amount)` | Irrevocable donation. New periods need at least 604800 minor units including queued funds. Active periods retain their end time. |
| Restart idle rewards | Vault `restartRewards()` | Prior period finished and `unallocatedRewards() >= 604800`. Anyone can call without approval or token payment. |

No method is payable. Do not attach ETH, use a recipient parameter, or transfer tokens directly to fund or stake. Preflight reads can race with another transaction; simulate, handle reverts, and refresh state from the receipt's chain. `fundRewards` has no rate or deadline slippage argument: donors accept the on-chain schedule when mined. The UI should make this clear, especially close to a period boundary.

## Events and errors

Events: `Staked(account, amount, unlockAt)`, `Unstaked(account, amount)`, `RewardClaimed(account, amount)`, `RewardsFunded(funder, amount, rate, finish)`, `RewardsRestarted(caller, rate, finish)`. The account/funder/caller is indexed. Use events to refresh reads; logs alone do not report continuously accruing rewards.

Vault errors: `InvalidToken`, `ZeroAmount`, `InsufficientStake`, `StakeLocked(unlockAt)`, `NoRewards`, `InsufficientRewardFunding`, `ActiveRewardPeriod`, `UnexpectedTokenAmount`. SafeERC20 and ReentrancyGuard errors, token allowance/balance errors, and checked-arithmetic reverts may also propagate. The ABI exports include declared inherited/library errors. A transfer failure rolls back the whole operation, leaving stakes and claims available for retry.

The generated manifest and its independent review are handled by separate contributors. Source deployment needs `LaunchToken()` followed by `StakingVault($token)`, with application identifier `StakingVault`. Do not add a privileged owner or initialization call. These files do not contain policy, signed attestations, chain addresses, or a manifest.
