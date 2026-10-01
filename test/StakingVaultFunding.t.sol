// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

contract StakingVaultFundingTest is Test {
    LaunchToken internal token;
    StakingVault internal vault;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal donor = address(0xD0);
    uint256 internal constant DURATION = 7 days;
    uint256 internal start;

    function setUp() public {
        vm.warp(1_000_000);
        start = block.timestamp;
        token = new LaunchToken();
        vault = new StakingVault(address(token));
        token.transfer(alice, 1_000_000 ether);
        token.transfer(bob, 1_000_000 ether);
        token.transfer(donor, 10_000_000 ether);
        vm.prank(alice);
        token.approve(address(vault), 1_000_000 ether);
        vm.prank(bob);
        token.approve(address(vault), 1_000_000 ether);
        vm.prank(donor);
        token.approve(address(vault), 10_000_000 ether);
    }

    function _fund(uint256 amount) internal {
        vm.prank(donor);
        vault.fundRewards(amount);
    }

    function test_lastSecondTopUpKeepsIdleQueueForSevenDayRestart() public {
        _fund(DURATION * 1 ether);
        vm.warp(start + DURATION - 1);
        vm.startPrank(alice);
        vault.stake(1);
        vm.expectRevert(StakingVault.ActiveRewardPeriod.selector);
        vault.restartRewards();
        vault.fundRewards(1);
        vm.stopPrank();

        uint256 idle = (DURATION - 1) * 1 ether;
        assertEq(vault.queuedRewards(), idle);
        assertEq(vault.rewardRate(), 1 ether + 1);
        assertEq(vault.periodFinish(), start + DURATION);
        vm.warp(start + DURATION);
        vm.prank(alice);
        assertEq(vault.claim(), 1 ether + 1);
        assertEq(vault.rewardReserve(), idle);

        // The old queue can now be restarted, and future entrants share the new stream.
        vm.prank(bob);
        vault.stake(1);
        vault.restartRewards();
        assertEq(vault.periodFinish(), start + 2 * DURATION);
        assertEq(vault.rewardRate(), idle / DURATION);
        assertEq(vault.queuedRewards(), idle % DURATION);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.earned(bob), 0);
        vm.warp(start + 2 * DURATION);
        uint256 share = (idle / DURATION) * DURATION / 2;
        vm.prank(alice);
        assertEq(vault.claim(), share);
        vm.prank(bob);
        assertEq(vault.claim(), share);
        assertEq(vault.rewardReserve(), vault.queuedRewards());
        vm.prank(alice);
        vault.unstake(1);
        vm.prank(bob);
        vault.unstake(1);
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(address(vault)), vault.rewardReserve());
    }

    function testFuzz_activeTopUpsPreserveIdleAndDustUntilNewPeriod(
        uint256 idleSeconds,
        uint256 rate,
        uint256 dust,
        uint256 added
    ) public {
        idleSeconds = bound(idleSeconds, 1, DURATION - 1);
        rate = bound(rate, 1, 1 ether);
        dust = bound(dust, 0, DURATION - 1);
        added = bound(added, 1, DURATION * 1 ether);
        uint256 funding = DURATION * rate + dust;
        _fund(funding);
        vm.warp(start + idleSeconds);
        uint256 remaining = DURATION - idleSeconds;

        // Funding itself checkpoints idle emissions, even before a staker arrives.
        _fund(added);
        uint256 queued = idleSeconds * rate + dust + added % remaining;
        assertEq(vault.queuedRewards(), queued);
        vm.prank(alice);
        vault.stake(1);
        _fund(added);
        queued += added % remaining;
        assertEq(vault.queuedRewards(), queued);
        assertEq(vault.rewardRate(), rate + 2 * (added / remaining));
        assertEq(vault.periodFinish(), start + DURATION);
        vm.warp(start + DURATION);
        vm.prank(alice);
        uint256 paid = vault.claim();
        assertEq(paid + queued, funding + 2 * added);
        assertEq(vault.rewardReserve(), queued);

        // A donation at expiry incorporates the queue into a full new week.
        _fund(DURATION);
        assertEq(vault.periodFinish(), start + 2 * DURATION);
        assertEq(vault.rewardRate(), (queued + DURATION) / DURATION);
        assertEq(vault.queuedRewards(), (queued + DURATION) % DURATION);
        assertEq(token.balanceOf(address(vault)), vault.totalStaked() + vault.rewardReserve());
    }

    function test_unboundedLateTopUpUsesRemainingSecondAndCurrentWeights() public {
        vm.prank(alice);
        vault.stake(100 ether);
        _fund(DURATION * 1 ether);
        vm.warp(start + DURATION - 1);
        vm.prank(bob);
        vault.stake(1_000_000 ether);
        _fund(DURATION * 1 ether);
        assertEq(vault.periodFinish(), start + DURATION);
        assertEq(vault.rewardRate(), (DURATION + 1) * 1 ether);
        vm.warp(start + DURATION);
        assertGt(vault.earned(bob), 604_700 ether);
        assertLt(vault.earned(alice) - (DURATION - 1) * 1 ether, 120 ether);
    }

    function test_minDurationAcceptsExactNewAndActivePeriodBoundaries() public {
        vm.prank(alice);
        vault.stake(1);
        vm.prank(donor);
        vault.fundRewards(DURATION * 1 ether, DURATION);
        assertEq(vault.periodFinish(), start + DURATION);
        vm.warp(start + 100);
        vm.prank(donor);
        vault.fundRewards((DURATION - 100) * 1 ether, DURATION - 100);
        assertEq(vault.periodFinish(), start + DURATION);
        assertEq(vault.rewardRate(), 2 ether);
        assertEq(vault.earned(alice), 100 ether);
        vm.warp(start + 101);
        assertEq(vault.earned(alice), 102 ether);
    }

    function test_minDurationRejectsDelayedTopUpWithoutMovingDonorFunds() public {
        vm.prank(alice);
        vault.stake(100 ether);
        _fund(DURATION * 1 ether);
        uint256 minDuration = DURATION / 2;
        vm.warp(start + DURATION - 1);
        vm.prank(bob);
        vault.stake(1_000_000 ether);
        uint256 walletBefore = token.balanceOf(donor);
        uint256 allowanceBefore = token.allowance(donor, address(vault));
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardDurationTooShort.selector, 1, minDuration));
        vault.fundRewards(DURATION * 1 ether, minDuration);
        assertEq(token.balanceOf(donor), walletBefore);
        assertEq(token.allowance(donor, address(vault)), allowanceBefore);
        assertEq(vault.rewardReserve(), DURATION * 1 ether);
        assertEq(vault.rewardRate(), 1 ether);
        assertEq(vault.periodFinish(), start + DURATION);
        assertEq(vault.queuedRewards(), 0);
        vm.warp(start + DURATION);
        assertLt(vault.earned(bob), 1 ether);

        // A retry after expiry now buys a full seven-day stream.
        vm.prank(donor);
        vault.fundRewards(DURATION * 1 ether, DURATION);
        assertEq(vault.periodFinish(), start + 2 * DURATION);
        assertEq(vault.rewardRate(), 1 ether);
    }

    function test_guardedFundingPreservesIdleQueueAndRevertsCheckpointAtomically() public {
        _fund(DURATION * 1 ether);
        vm.warp(start + DURATION - 1);
        uint256 walletBefore = token.balanceOf(donor);
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardDurationTooShort.selector, 1, 2));
        vault.fundRewards(1, 2);
        assertEq(vault.queuedRewards(), 0);
        assertEq(vault.unallocatedRewards(), (DURATION - 1) * 1 ether);
        assertEq(vault.lastUpdateTime(), start);
        assertEq(vault.rewardRate(), 1 ether);
        assertEq(vault.rewardReserve(), DURATION * 1 ether);
        assertEq(token.balanceOf(donor), walletBefore);

        vm.prank(alice);
        vault.stake(1);
        vm.prank(donor);
        vault.fundRewards(1, 1);
        assertEq(vault.queuedRewards(), (DURATION - 1) * 1 ether);
        assertEq(vault.rewardRate(), 1 ether + 1);
        assertEq(vault.periodFinish(), start + DURATION);
        vm.warp(start + DURATION);
        assertEq(vault.earned(alice), 1 ether + 1);
    }

    function test_minDurationAboveOneWeekAndZeroDonationRevert() public {
        uint256 walletBefore = token.balanceOf(donor);
        vm.startPrank(donor);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardDurationTooShort.selector, DURATION, DURATION + 1));
        vault.fundRewards(DURATION * 1 ether, DURATION + 1);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.fundRewards(0, DURATION);
        vm.stopPrank();
        assertEq(vault.periodFinish(), 0);
        assertEq(vault.lastUpdateTime(), 0);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(donor), walletBefore);
    }
}
