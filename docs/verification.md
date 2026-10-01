# Local verification and security triage

This is the implementation contributor's verification record, not an independent audit. The supplied protected tests were read as acceptance definitions. Their service-injected deployment environment is not available locally, so those files were not executed or altered. Delivered tests independently exercise factory construction, fixed supply, runtime size, opcode restrictions, and application behavior without environment variables.

## Executed tools

| Command | Result |
| --- | --- |
| `forge --version` | Foundry 1.8.3 |
| `slither --version` | Slither 0.11.6 |
| `command -v aderyn` | No executable found in the effective PATH; Aderyn not run |
| `forge build` | Passed with Solc 0.8.26; lint warnings discussed below |
| `forge test` | 32 passed, 0 failed, 0 skipped; two fuzz tests at 256 runs each; invariant at 128 runs × 64 calls = 8192 calls, 0 reverts |
| `forge fmt` / `forge fmt --check` | Formatted project files; check passed |
| `forge inspect LaunchToken abi --json` / `forge inspect StakingVault abi --json` | Exported ABI arrays in `docs/abi/` |
| `slither . --filter-paths 'lib/\|test/' --json /tmp/sevenday-slither.json` | Analysis completed: 14 contracts, 102 detectors, 10 findings; exit 255 because findings were reported |
| `forge build --offline`, `forge test --offline`, `forge fmt --check` in a fresh standalone copy | Passed without `.imd` inputs or a project build cache; all 32 tests passed again, including 8192 invariant calls with 0 reverts |
| Python JSON comparison of exported ABIs against standalone build artifacts | Both ABI arrays match exactly |
| `sha256sum --check docs/dependency-checksums.sha256` | All 41 vendored files match |

The actual Slither argument was the regular expression `lib/|test/` (the backslash in the table only escapes Markdown's column delimiter). Dependencies and test harnesses were excluded from finding presentation, not from compilation. No detector suppression annotations or exclusions were added to the implementation.

The standalone check copied only `src/`, `test/`, `lib/`, `foundry.toml`, and `remappings.txt` into a temporary directory and used the preinstalled version-pinned compiler. No downloaded compiler or build artifact is part of the deliverable. Compiled production runtime sizes are 1784 bytes for LaunchToken and 4411 bytes for StakingVault.

Aderyn was requested but unavailable. Mythril was not run. No live-chain checks, signed transactions, deployment, or production independent review were performed. This assignment supplies the source and tests needed for the later review stage.

## Meaningful coverage

- Token metadata, exact 10^27 supply minted only at construction, exact transfers, balance/allowance failures, and absent common privileged entrypoints.
- Factory construction preserves all launch supply; application constructor rejects zero/no-code assets. Production runtimes are nonempty, at most 24,576 bytes, and contain no executable DELEGATECALL, CALLCODE, or SELFDESTRUCT (PUSH data is skipped).
- Lock expiry at its exact boundary, a one-second-early failure, wallet-wide reset on additional stake, partial/full exit, duplicate withdrawals/claims, and isolation of users.
- Per-second weighted accrual, late entrants, checkpointing before weight changes, claim during lock and after exit, period rollover with outstanding claims, fixed-end top-ups, idle periods, and permissionless restart.
- Schedule dust, minimal funding, preserved fractional user accrual, unsolicited-transfer isolation, and APR display semantics.
- Failed/false-returning transfers roll back accounting; taxed deposits are rejected. A hostile token attempts every mutating entrypoint on deposit, funding, claim, and withdrawal and verifies that each nested call is rejected by the reentrancy guard.
- Stateful invariant sequences mix four actors, time changes, staking, withdrawals, claims, funding, idle restarts, and donations. They check principal sums, token conservation, exact reserve accounting, and the backing of aggregate earned/future/queued liabilities. Each run finishes by unlocking and exiting all actors, confirming that every actor can recover all principal.

## Slither findings

All 10 reported findings were inspected against the supplied token, guarded call paths, and tests. No exploitable source defect was identified by this local triage; this conclusion does not establish absence of defects.

| Detector | Count | Assessment |
| --- | --- | --- |
| `weak-prng` | 2 | False positives. `_accrual` and `_schedule` use modulo solely for accounting remainders. There is no random winner, seed, or randomness-dependent privilege. |
| `reentrancy-balance` | 1 | False positive for the supported LaunchToken. `_pullExact` intentionally snapshots the balance before `safeTransferFrom` and verifies the increase afterward. Both callers (`stake`, `fundRewards`) are guarded; all five mutable entrypoints reject callback reentry. LaunchToken has no callbacks. Arbitrary malicious/rebasing tokens remain unsupported. |
| `incorrect-equality` | 2 | Intentional zero checks: `claim` rejects no whole rewards; `_schedule` rejects an unfunded zero-rate period. Neither requires an externally controlled balance to reach a particular value. |
| `timestamp` | 5 | Accepted mechanism/trust assumption. `unstake`, `claim`, `restartRewards`, `aprBps`, and `_schedule` depend on seconds for the requested lock and reward stream. Tests cover boundaries; chain timestamp variation is not eliminated. No timestamp-derived randomness or oracle value is used. |

Slither assigned High/Medium confidence to the two weak-PRNG findings and the balance-reentrancy finding, Medium/High confidence to the two equality findings, and Low/Medium confidence to the five timestamp findings. These are the analyzer's severity/confidence labels; the contextual assessments above explain why they are false positives or accepted mechanism assumptions here.

Foundry's linter additionally flags events after token interactions, timestamp comparisons, and strict balance-delta equality. Token interactions use checks/effects before transfers and a common reentrancy guard; failed calls roll back events and state, and successful event values cannot be changed through nested mutable entrypoints. The equality check deliberately rejects any incoming amount discrepancy. The warnings are documented, not suppressed.

## Review assumptions and remaining service work

Only the delivered non-rebasing, fee-free token is supported; code presence alone in the constructor is not proof of that identity. The manifest must bind `$token` correctly. There are no privileged wallets to configure. Funding is voluntary, irreversible, and denominated in SEVEN; adding a stake relocks that wallet's whole position. Dust and mistakenly transferred assets have no rescue path. The vault is immutable, so a discovered defect cannot be patched in place.

The independent reviewer should assess the source and generated manifest together. Publication, artifact verification, policy/attestation linkage, admission, actual deployment, chain/address/pool-key handoff, and IPFS hosting are service responsibilities. Funding and optional idle-queue restarts are post-deployment actions by token holders. None is a prerequisite for completing this source assignment.
