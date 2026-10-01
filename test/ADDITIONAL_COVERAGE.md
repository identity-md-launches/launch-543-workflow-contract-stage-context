# Additional test coverage

This contribution adds and extends tests only. The accepted source, dependencies and configuration are unchanged.

## Revision: guarded funding and reserved rewards

This revision extends the existing boundary tests and cash-flow handler for the accepted funding changes:

- Two new fuzz properties, 1,000 runs each, check duration rejection followed by an exact-duration retry, and equivalence between the unguarded overload and a zero minimum. Inputs span active and expired periods, both with stakers and with idle emissions. Rejection compares all tracked account state, checkpoints, schedules, balances and allowances; successful funding checks budget conservation and pre-existing rewards.
- A deterministic rollover regression checks maximum-duration rejection, insufficient allowance after scheduling, and a successful retry that preserves idle rewards, dust and existing claims.
- The existing four-actor invariant now randomly calls both funding overloads. Active top-ups must preserve the unallocated queue and conserve the sum of future emissions and queued rewards. Rejected guarded calls must restore the entire tracked state. A deterministic handler test requires successful and rejected calls before and after expiry, then settles all principal.

The incoming tree passed 60 tests. The focused revision run passed 17 tests. Final checks used fresh build and cache directories outside the repository:

```sh
FOUNDRY_OUT=/tmp/imd-e3029858-final-out FOUNDRY_CACHE_PATH=/tmp/imd-e3029858-final-cache forge build --offline
FOUNDRY_OUT=/tmp/imd-e3029858-final-out FOUNDRY_CACHE_PATH=/tmp/imd-e3029858-final-cache forge test --offline
```

Both exited 0: **64 tests passed, 0 failed, 0 skipped** across nine suites. The extended vault invariant completed 256 sequences of 128 calls (32,768 calls), including 3,197 guarded-handler calls, with zero unexpected reverts. The existing custody and token invariants also passed. Build lint warnings concerned source timestamps, events after transfers, exact balance checks, and existing handler reads of `block.timestamp` around `vm.warp`; none were suppressed. No confirmed defect requiring a findings report was identified. The protected service harnesses were read, but their service-configured deployment checks were not run locally.

## Properties and assumptions

- `StakingVaultBoundaries.t.sol`: failed deposits, active top-ups and expired-period funding restore account state, reward checkpoints, locks, schedules, balances and allowances. Also covers sub-minimum funding retries, duplicate claims, fractional rewards across exit/re-entry, exact period boundaries, one-wei principal, full supply, maximum integer rejection and fuzzed top-ups.
- `StakingVaultModelInvariant.t.sol`: four actors stake, withdraw, claim, fund, donate, advance time, restart rewards and attempt prohibited operations in random order. Independent cash-flow totals determine every wallet's principal, balance and unlock time. A direct per-wallet integration of elapsed emissions checks lifetime paid plus pending rewards, without reproducing the vault's reward-index/checkpoint implementation. Every sequence ends with all principal withdrawn and whole rewards claimed.
- `LaunchTokenAuthorization.t.sol`: authorization failures, allowance rollback/replacement/revocation, unlimited approvals, self/zero transfers, and a separate four-actor state machine that checks balances and all 16 owner/spender allowances after random transfers and approvals.

The vault model uses the actual configured emission rate and deadline; it independently tests their allocation, not the scheduling algorithm. Dedicated boundary/fuzz tests additionally check scheduling conservation, deadline preservation and nondecreasing active rates. The reward comparison permits one **minor token unit**, not one token: fewer than 256 checkpoints at the fixed 10^27 supply and 10^36 index precision lose less than one minor unit to global rounding. The existing backing invariant also checks pending rewards, queued rewards and future emissions against the reserve.

The supported asset is the accepted LaunchToken. These tests do not claim compatibility with arbitrary rebasing or malicious tokens. New tests use no forks, FFI, environment mutation or network dependencies.

## Prior-round executed checks

Foundry 1.8.3 and Solc 0.8.26 were available. Build artifacts and analysis output were directed into disposable `test/scratch/` using process environment variables, without changing configuration files.

Final checks, with fresh output/cache directories:

```sh
FOUNDRY_OUT=test/scratch/final-out FOUNDRY_CACHE_PATH=test/scratch/final-cache forge build --offline
FOUNDRY_OUT=test/scratch/final-out FOUNDRY_CACHE_PATH=test/scratch/final-cache forge test --offline
```

Both exited 0. The build compiled 38 files. The complete suite passed **53 tests, 0 failures, 0 skips**:

- Two new fuzz properties: 1,000 runs each; existing fuzz properties: 256 runs each.
- New vault invariant: 256 sequences x 128 calls = 32,768 calls, zero unexpected reverts.
- New token invariant: 256 sequences x 128 calls = 32,768 calls, zero unexpected reverts.
- Existing vault invariant: 128 sequences x 64 calls = 8,192 calls, zero unexpected reverts.

Before adding tests, `forge build` and `forge test --offline` also passed (32 baseline tests). Focused `forge test --offline --match-path` runs for the three new Solidity files were executed using `FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache`. The first token run had one test-harness error: it expected `ERC20InvalidSender` for a zero source, while vendored OpenZeppelin rejects the allowance owner first with `ERC20InvalidApprover`. The expectation was corrected after inspecting that dependency; the final complete run above passed. No implementation failure was asserted as correct or hidden.

## Prior-round static analysis

Executed after the initial successful build:

```sh
command -v forge
command -v slither
command -v aderyn
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache slither . --skip-clean --foundry-out-directory test/scratch/out --filter-paths 'lib/|test/' --json test/scratch/slither.json
```

Slither completed 102 detectors over 14 contracts and exited 255 because it reported 10 findings. All were reviewed against the unchanged source:

| Detector | Count | Assessment |
| --- | ---: | --- |
| `weak-prng` | 2 | False positives: modulo computes accounting remainders; there is no randomness. |
| `reentrancy-balance` | 1 | False positive for the accepted token and guarded callers: the before/after balance comparison enforces exact incoming amounts. Existing callback tests exercise all mutable entrypoints. |
| `incorrect-equality` | 2 | Intentional rejection of zero claimable rewards or a zero funded rate. |
| `timestamp` | 5 | Timestamps implement the required lock and per-second schedule; boundary behavior is tested. Validator timestamp discretion remains an assumption. |

The build also emitted source lint warnings for timestamps, events after token transfers and strict balance-delta equality. Transfers are guarded, failed calls revert their state, and exact incoming amounts are intentional. No warning was suppressed.

`command -v aderyn` found no executable, so Aderyn was not run. The service-configured protected tests were read but not executed: their deployment environment is supplied by the verifier. No transactions, signatures, deployment or independent launch-manifest review were performed.

No confirmed source defect requiring a findings report was identified. Passing checks do not establish absence of vulnerabilities.
