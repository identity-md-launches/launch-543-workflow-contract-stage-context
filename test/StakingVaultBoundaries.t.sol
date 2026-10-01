// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {StakingVault} from "src/StakingVault.sol";

contract StakingVaultBoundariesTest is Test {
    LaunchToken internal token;
    StakingVault internal vault;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant DONOR = address(0xD0);
    uint256 internal constant D = 7 days;
    uint256 internal constant START = 1_000_000;

    function setUp() public {
        vm.warp(START);
        token = new LaunchToken();
        vault = new StakingVault(address(token));
        address[3] memory actors = [ALICE, BOB, DONOR];
        for (uint256 i; i < actors.length; ++i) {
            token.transfer(actors[i], 2e26);
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function test_failedAdditionPreservesAccrualAndOriginalUnlock() public {
        _stake(ALICE, 100 ether);
        _fund(D * 1 ether);
        vm.warp(START + D - 1);
        vm.prank(ALICE);
        token.approve(address(vault), 0);
        bytes32 beforeState = _state();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.stake(1);
        assertEq(_state(), beforeState, "failed pull must undo the reward checkpoint and lock reset");
        vm.warp(START + D);
        vm.prank(ALICE);
        vault.unstake(100 ether);
        vm.prank(ALICE);
        assertEq(vault.claim(), D * 1 ether);
    }

    function test_failedTopUpPreservesActiveScheduleAndAllAccounts() public {
        _stake(ALICE, 3 ether);
        _stake(BOB, 5 ether);
        _fund(D * 8 ether + 1);
        vm.warp(START + 123);
        vm.prank(DONOR);
        token.approve(address(vault), 6);
        bytes32 beforeState = _state();
        vm.prank(DONOR);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 6, 7));
        vault.fundRewards(7);
        assertEq(_state(), beforeState, "failed funding cannot consume dust or alter the rate");
    }

    function test_failedRolloverRestoresIdleQueueAndSpentAllowance() public {
        _fund(D);
        vm.warp(START + D + 1);
        uint256 wallet = token.balanceOf(DONOR);
        vm.prank(DONOR);
        token.approve(address(vault), wallet + 1);
        bytes32 beforeState = _state();
        vm.prank(DONOR);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DONOR, wallet, wallet + 1)
        );
        vault.fundRewards(wallet + 1);
        assertEq(_state(), beforeState, "failed new period must restore pending idle emissions and allowance");
        vm.prank(BOB);
        vault.restartRewards();
        assertEq(vault.rewardRate(), 1);
        assertEq(vault.periodFinish(), START + 2 * D + 1);
        assertEq(vault.rewardReserve(), D);
    }

    function test_maximumWithdrawalAndDepositCannotCreateAnUnbackedPosition() public {
        _stake(ALICE, 1);
        _fund(D);
        vm.warp(START + 1);
        vm.prank(ALICE);
        vm.expectRevert(StakingVault.InsufficientStake.selector);
        vault.unstake(type(uint256).max);
        bytes32 beforeState = _state();
        StakingVault empty = new StakingVault(address(token));
        vm.prank(BOB);
        token.approve(address(empty), type(uint256).max);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 2e26, type(uint256).max)
        );
        empty.stake(type(uint256).max);
        assertEq(empty.totalStaked(), 0);
        assertEq(empty.balanceOf(BOB), 0);
        assertEq(empty.unlockTime(BOB), 0);
        assertEq(_state(), beforeState);
    }

    function test_claimDuringLockDoesNotRelockAndDuplicateClaimIsAtomic() public {
        _stake(ALICE, 1);
        _fund(D * 2);
        vm.warp(START + 1);
        vm.prank(ALICE);
        assertEq(vault.claim(), 2);
        assertEq(vault.unlockTime(ALICE), START + D);
        bytes32 beforeState = _state();
        vm.prank(ALICE);
        vm.expectRevert(StakingVault.NoRewards.selector);
        vault.claim();
        assertEq(_state(), beforeState);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StakeLocked.selector, START + D));
        vault.unstake(1);
    }

    function test_lastSecondFundingIsPaidBeforeAnExactBoundaryRollover() public {
        _stake(ALICE, 1);
        _fund(D);
        vm.warp(START + D - 1);
        _fund(123);
        assertEq(vault.periodFinish(), START + D);
        assertEq(vault.rewardRate(), 124);
        assertEq(vault.earned(ALICE), D - 1);
        vm.warp(START + D);
        _fund(D * 2);
        assertEq(vault.earned(ALICE), D + 123);
        assertEq(vault.periodFinish(), START + 2 * D);
        vm.warp(START + D + 1);
        vm.prank(ALICE);
        assertEq(vault.claim(), D + 125);
        assertEq(vault.rewardReserve(), 2 * D - 2);
    }

    function test_fractionalRewardsSurviveFullExitIdleTimeAndRestake() public {
        _stake(ALICE, 1);
        _stake(BOB, 7);
        vm.warp(START + D);
        _fund(D * 3);
        vm.warp(START + D + 1);
        vm.prank(ALICE);
        vault.unstake(1);
        assertEq(vault.rewardRemainder(ALICE), 3e36 / 8);
        vm.prank(ALICE);
        vm.expectRevert(StakingVault.NoRewards.selector);
        vault.claim();
        vm.warp(START + D + 4);
        _stake(ALICE, 1);
        assertEq(vault.earned(ALICE), 0, "no earnings during absence");
        vm.warp(START + D + 6);
        vm.prank(ALICE);
        assertEq(vault.claim(), 1);
        assertEq(vault.rewardRemainder(ALICE), 1e36 / 8);
    }

    function test_failedSubminimumFundingIsRefundedAndCanBeRetried() public {
        _fund(D + 1);
        vm.warp(START + D);
        // Entire idle period is queued; all but one unit is distributed on restart.
        _stake(ALICE, 1);
        vault.restartRewards();
        vm.warp(START + 2 * D);
        bytes32 beforeState = _state();
        vm.prank(DONOR);
        vm.expectRevert(StakingVault.InsufficientRewardFunding.selector);
        vault.fundRewards(D - 2);
        assertEq(_state(), beforeState);
        _fund(D - 1);
        assertEq(vault.rewardRate(), 1);
        assertEq(vault.queuedRewards(), 0);
        assertEq(vault.earned(ALICE), D, "new funding must not reuse outstanding claims");
    }

    function test_oneWeiPrincipalCanReceiveAlmostEntireSupplyWithoutOverflow() public {
        LaunchToken fresh = new LaunchToken();
        StakingVault large = new StakingVault(address(fresh));
        fresh.approve(address(large), type(uint256).max);
        large.stake(1);
        large.fundRewards(1e27 - 1);
        uint256 rate = (1e27 - 1) / D;
        assertEq(large.aprBps(), rate * 365 days * 10_000);
        vm.warp(START + D);
        assertEq(large.claim(), rate * D);
        large.unstake(1);
        assertEq(fresh.balanceOf(address(this)), 1 + rate * D);
        assertEq(fresh.balanceOf(address(large)), (1e27 - 1) % D);
    }

    function test_entireSupplyCanBeStakedAndRecoveredWithoutRewards() public {
        LaunchToken fresh = new LaunchToken();
        StakingVault full = new StakingVault(address(fresh));
        fresh.approve(address(full), 1e27);
        full.stake(1e27);
        assertEq(full.totalStaked(), 1e27);
        vm.warp(START + D);
        full.unstake(1e27);
        assertEq(fresh.balanceOf(address(this)), 1e27);
        assertEq(fresh.balanceOf(address(full)), 0);
        assertEq(full.rewardReserve(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allTopUpsPreserveDeadlineAndPayOnlyElapsedRewards(uint256 elapsed, uint256 added) public {
        elapsed = bound(elapsed, 0, D - 1);
        added = bound(added, 1, 1e25);
        _stake(ALICE, 1);
        _fund(D * 2);
        vm.warp(START + elapsed);
        _fund(added);
        assertEq(vault.periodFinish(), START + D);
        assertEq(vault.earned(ALICE), elapsed * 2);
        assertGe(vault.rewardRate(), 2);
        // Only division dust may be excluded from this sole staker's final payment.
        vm.warp(START + D);
        vm.prank(ALICE);
        uint256 paid = vault.claim();
        assertEq(paid + vault.queuedRewards(), D * 2 + added);
        assertLt(vault.queuedRewards(), D - elapsed);
        assertEq(token.balanceOf(address(vault)), 1 + vault.queuedRewards());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_guardedFundingRejectsThenAcceptsExactDuration(uint256 elapsed, uint256 added, bool idle) public {
        elapsed = bound(elapsed, 0, 2 * D);
        added = bound(added, D, 1e25);
        if (!idle) {
            _stake(ALICE, 3);
            _stake(BOB, 5);
        }
        _fund(D * 8 + 5);
        vm.warp(START + elapsed);
        vm.prank(DONOR);
        token.approve(address(vault), added);
        uint256 duration = elapsed < D ? D - elapsed : D;
        uint256 queued = vault.unallocatedRewards();
        bytes32 beforeState = _state();

        vm.prank(DONOR);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardDurationTooShort.selector, duration, duration + 1));
        vault.fundRewards(added, duration + 1);
        assertEq(_state(), beforeState, "duration rejection must undo all checkpoints and scheduling");

        vm.prank(DONOR);
        vault.fundRewards(added, duration);
        assertEq(token.allowance(DONOR, address(vault)), 0);
        assertEq(token.balanceOf(DONOR), 2e26 - (D * 8 + 5) - added);
        assertEq(vault.rewardReserve(), D * 8 + 5 + added);
        assertEq(vault.periodFinish(), START + elapsed + duration);
        assertEq(vault.earned(ALICE), idle ? 0 : 3 * (elapsed < D ? elapsed : D));
        assertEq(vault.earned(BOB), idle ? 0 : 5 * (elapsed < D ? elapsed : D));
        if (elapsed < D) assertGe(vault.queuedRewards(), queued, "active funding must preserve the queue");
        assertEq(
            duration * vault.rewardRate() + vault.queuedRewards(),
            queued + added + (elapsed < D ? 8 * (D - elapsed) : 0),
            "funding must conserve the undistributed budget"
        );
        assertEq(token.balanceOf(address(vault)), vault.totalStaked() + vault.rewardReserve());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_zeroMinimumMatchesUnguardedFunding(uint256 elapsed, uint256 added, bool idle) public {
        elapsed = bound(elapsed, 0, 2 * D);
        added = bound(added, D, 1e25);
        _fund(D * 8 + 5);
        if (!idle) {
            vm.warp(START + D / 2);
            _stake(ALICE, 3);
            _stake(BOB, 5);
        }
        vm.warp(block.timestamp + elapsed);
        uint256 snapshot = vm.snapshotState();
        _fund(added);
        bytes32 unguardedState = _state();
        assertTrue(vm.revertToState(snapshot));
        vm.prank(DONOR);
        vault.fundRewards(added, 0);
        assertEq(_state(), unguardedState, "zero minimum must preserve the existing overload's behavior");
    }

    function test_guardedRolloverRejectsMaximumDurationAndFailedPullWithoutLosingQueue() public {
        _fund(D * 8 + 5);
        vm.warp(START + 100);
        _stake(ALICE, 3);
        _stake(BOB, 5);
        vm.warp(START + D + 1);
        bytes32 beforeState = _state();
        vm.prank(DONOR);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardDurationTooShort.selector, D, type(uint256).max));
        vault.fundRewards(D, type(uint256).max);
        assertEq(_state(), beforeState);

        vm.prank(DONOR);
        token.approve(address(vault), D - 1);
        beforeState = _state();
        vm.prank(DONOR);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), D - 1, D)
        );
        vault.fundRewards(D, D);
        assertEq(_state(), beforeState, "failed pull must undo consumption of idle emissions and dust");

        vm.prank(DONOR);
        token.approve(address(vault), D);
        vm.prank(DONOR);
        vault.fundRewards(D, D);
        assertEq(vault.queuedRewards(), 805);
        assertEq(vault.rewardRate(), 1);
        assertEq(vault.periodFinish(), START + 2 * D + 1);
        assertEq(vault.earned(ALICE), (D - 100) * 3);
        assertEq(vault.earned(BOB), (D - 100) * 5);
    }

    function _stake(address actor, uint256 amount) internal {
        vm.prank(actor);
        vault.stake(amount);
    }

    function _fund(uint256 amount) internal {
        vm.prank(DONOR);
        vault.fundRewards(amount);
    }

    function _state() internal view returns (bytes32) {
        bytes32 global = keccak256(
            abi.encode(
                vault.totalStaked(),
                vault.rewardReserve(),
                vault.rewardRate(),
                vault.periodFinish(),
                vault.lastUpdateTime(),
                vault.rewardPerTokenStored(),
                vault.queuedRewards(),
                token.balanceOf(address(vault))
            )
        );
        return keccak256(abi.encode(global, _account(ALICE), _account(BOB), _account(DONOR)));
    }

    function _account(address actor) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.balanceOf(actor),
                vault.unlockTime(actor),
                vault.rewards(actor),
                vault.rewardRemainder(actor),
                vault.userRewardPerTokenPaid(actor),
                vault.earned(actor),
                token.balanceOf(actor),
                token.allowance(actor, address(vault))
            )
        );
    }
}
