// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

contract StakingVaultTest is Test {
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

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        vault.stake(amount);
    }

    function _fund(uint256 amount) internal {
        vm.prank(donor);
        vault.fundRewards(amount);
    }

    function test_constructorIsFullyConfiguredAndDoesNotMoveSupply() public {
        LaunchToken fresh = new LaunchToken();
        StakingVault deployed = new StakingVault(address(fresh));
        assertEq(address(deployed.token()), address(fresh));
        assertEq(fresh.balanceOf(address(this)), 1e27);
        assertEq(fresh.balanceOf(address(deployed)), 0);
        assertEq(deployed.LOCK_DURATION(), 7 days);
        assertEq(deployed.REWARD_DURATION(), 7 days);
        vm.expectRevert(StakingVault.InvalidToken.selector);
        new StakingVault(address(0));
        vm.expectRevert(StakingVault.InvalidToken.selector);
        new StakingVault(alice);
    }

    function test_lockBoundaryPartialAndFullExit() public {
        uint256 beforeBalance = token.balanceOf(alice);
        _stake(alice, 100 ether);
        assertEq(vault.totalStaked(), 100 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.unlockTime(alice), start + DURATION);
        vm.warp(start + DURATION - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StakeLocked.selector, start + DURATION));
        vault.unstake(1);
        vm.warp(start + DURATION);
        vm.prank(alice);
        vault.unstake(40 ether);
        assertEq(vault.unlockTime(alice), start + DURATION);
        assertEq(vault.balanceOf(alice), 60 ether);
        vm.prank(alice);
        vault.unstake(60 ether);
        assertEq(vault.unlockTime(alice), 0);
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(alice), beforeBalance);
        vm.prank(alice);
        vm.expectRevert(StakingVault.InsufficientStake.selector);
        vault.unstake(1);
    }

    function test_additionResetsWholeWalletLockButNotOthers() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        vm.warp(start + 6 days);
        _stake(alice, 1);
        assertEq(vault.unlockTime(alice), start + 13 days);
        assertEq(vault.unlockTime(bob), start + 7 days);
        vm.warp(start + 7 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StakeLocked.selector, start + 13 days));
        vault.unstake(100 ether);
        vm.prank(bob);
        vault.unstake(100 ether);
    }

    function test_zeroAndOverWithdrawalFailWithoutChangingAccounting() public {
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.stake(0);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.unstake(0);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.fundRewards(0);
        vm.expectRevert(StakingVault.NoRewards.selector);
        vault.claim();
        vm.expectRevert(StakingVault.InsufficientStake.selector);
        vault.unstake(1);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.rewardReserve(), 0);
    }

    function test_noAllowanceRevertsStakeAndFundingAtomically() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1 ether)
        );
        vault.stake(1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1 ether)
        );
        vault.fundRewards(1 ether);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.unlockTime(address(this)), 0);
        assertEq(vault.rewardReserve(), 0);
        assertEq(vault.periodFinish(), 0);
    }

    function test_noBalanceRevertsStakeAtomically() public {
        address empty = address(0xE);
        vm.startPrank(empty);
        token.approve(address(vault), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, empty, 0, 1 ether));
        vault.stake(1 ether);
        vm.stopPrank();
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.unlockTime(empty), 0);
    }

    function test_rewardsAccruePerSecondProRataAndStopAtFinish() public {
        _stake(alice, 100 ether);
        _stake(bob, 300 ether);
        _fund(DURATION * 4 ether);
        assertEq(vault.earned(alice), 0);
        vm.warp(start + 1);
        assertEq(vault.earned(alice), 1 ether);
        assertEq(vault.earned(bob), 3 ether);
        vm.warp(start + DURATION);
        assertEq(vault.earned(alice), DURATION * 1 ether);
        assertEq(vault.earned(bob), DURATION * 3 ether);
        vm.warp(start + 500 days);
        assertEq(vault.earned(alice), DURATION * 1 ether);
        assertEq(vault.earned(bob), DURATION * 3 ether);
        assertEq(vault.aprBps(), 0);
    }

    function test_claimDuringLockAndAfterFullExitConservesFunds() public {
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 donorBefore = token.balanceOf(donor);
        uint256 funding = DURATION * 1 ether;
        _stake(alice, 100 ether);
        _fund(funding);
        vm.warp(start + 1 days);
        vm.prank(alice);
        assertEq(vault.claim(), 1 days * 1 ether);
        assertEq(vault.totalStaked(), 100 ether);
        assertEq(vault.rewardReserve(), 6 days * 1 ether);
        assertEq(vault.unlockTime(alice), start + DURATION);
        vm.prank(alice);
        vm.expectRevert(StakingVault.NoRewards.selector);
        vault.claim();
        vm.warp(start + DURATION);
        vm.prank(alice);
        vault.unstake(100 ether);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.earned(alice), 6 days * 1 ether);
        vm.prank(alice);
        assertEq(vault.claim(), 6 days * 1 ether);
        assertEq(token.balanceOf(alice), aliceBefore + funding);
        assertEq(token.balanceOf(donor), donorBefore - funding);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_lateStakeReceivesOnlyFutureEmissions() public {
        _stake(alice, 100 ether);
        _fund(DURATION * 2 ether);
        vm.warp(start + 100);
        _stake(bob, 100 ether);
        assertEq(vault.earned(bob), 0);
        assertEq(vault.earned(alice), 200 ether);
        vm.warp(start + 200);
        assertEq(vault.earned(bob), 100 ether);
        assertEq(vault.earned(alice), 300 ether);
    }

    function test_withdrawalCheckpointsOldWeightBeforeChangingIt() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        vm.warp(start + DURATION);
        _fund(DURATION * 2 ether);
        vm.warp(start + DURATION + 100);
        vm.prank(alice);
        vault.unstake(100 ether);
        vm.warp(start + DURATION + 200);
        assertEq(vault.earned(alice), 100 ether);
        assertEq(vault.earned(bob), 300 ether);
    }

    function test_topUpPreservesFinishAndCannotDelayRewards() public {
        _stake(alice, 100 ether);
        _fund(DURATION * 1 ether);
        vm.warp(start + 100);
        uint256 finish = vault.periodFinish();
        _fund(1);
        assertEq(vault.periodFinish(), finish);
        assertEq(vault.rewardRate(), 1 ether);
        assertEq(vault.queuedRewards(), 1);
        assertEq(vault.earned(alice), 100 ether);
        _fund((DURATION - 100) * 2 ether);
        assertEq(vault.periodFinish(), finish);
        assertEq(vault.rewardRate(), 3 ether);
        vm.warp(start + 101);
        assertEq(vault.earned(alice), 103 ether);
    }

    function test_newPeriodPreservesUnclaimedOldRewards() public {
        _stake(alice, 100 ether);
        _fund(DURATION * 1 ether);
        vm.warp(start + DURATION + 20);
        _fund(DURATION * 2 ether);
        assertEq(vault.periodFinish(), block.timestamp + DURATION);
        assertEq(vault.earned(alice), DURATION * 1 ether);
        vm.warp(block.timestamp + 100);
        assertEq(vault.earned(alice), DURATION * 1 ether + 200 ether);
    }

    function test_idleEmissionsAreQueuedNotAwardedToFirstStaker() public {
        _fund(DURATION * 1 ether);
        vm.warp(start + 100);
        assertEq(vault.unallocatedRewards(), 100 ether);
        _stake(alice, 100 ether);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.queuedRewards(), 100 ether);
        vm.warp(start + 200);
        assertEq(vault.earned(alice), 100 ether);
    }

    function test_anyoneCanRestartIdleRewardsAndTheyRemainBacked() public {
        uint256 funding = DURATION * 1 ether;
        _fund(funding);
        vm.warp(start + DURATION);
        assertEq(vault.unallocatedRewards(), funding);
        _stake(alice, 100 ether);
        vm.prank(bob);
        vault.restartRewards();
        assertEq(vault.rewardReserve(), funding);
        assertEq(vault.rewardRate(), 1 ether);
        assertEq(vault.periodFinish(), start + 2 * DURATION);
        vm.warp(start + 2 * DURATION);
        vm.prank(alice);
        vault.claim();
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(vault)), vault.totalStaked());
    }

    function test_restartCannotChangeActivePeriodOrUsePrincipalOrEarnedRewards() public {
        _stake(alice, 100 ether);
        vm.expectRevert(StakingVault.InsufficientRewardFunding.selector);
        vault.restartRewards();
        _fund(DURATION);
        vm.expectRevert(StakingVault.ActiveRewardPeriod.selector);
        vault.restartRewards();
        vm.warp(start + DURATION);
        vm.expectRevert(StakingVault.InsufficientRewardFunding.selector);
        vault.restartRewards();
        assertEq(vault.earned(alice), DURATION);
        assertEq(vault.rewardReserve(), DURATION);
    }

    function test_minimumInitialFundingAndDivisionDust() public {
        vm.prank(donor);
        vm.expectRevert(StakingVault.InsufficientRewardFunding.selector);
        vault.fundRewards(DURATION - 1);
        assertEq(vault.rewardReserve(), 0);
        _fund(DURATION + 1);
        assertEq(vault.rewardRate(), 1);
        assertEq(vault.queuedRewards(), 1);
        assertEq(vault.rewardReserve(), DURATION + 1);
    }

    function test_fractionalUserRewardsSurviveFrequentClaims() public {
        _stake(alice, 3);
        _stake(bob, 5);
        _fund(DURATION * 3);
        for (uint256 i = 1; i <= 8; ++i) {
            vm.warp(start + i);
            vm.prank(alice);
            vault.claim();
        }
        // Alice earned 3/8 * 3 * 8 = 9 minor units despite eight checkpoints.
        assertEq(token.balanceOf(alice), 1_000_000 ether - 3 + 9);
        assertEq(vault.rewardRemainder(alice), 0);
        assertEq(vault.earned(bob), 15);
    }

    function test_donationsDoNotBecomeStakeOrRewardsAndDoNotDilute() public {
        _stake(alice, 1);
        token.transfer(address(vault), 10_000 ether);
        _stake(bob, 100 ether);
        assertEq(vault.balanceOf(bob), 100 ether);
        assertEq(vault.totalStaked(), 100 ether + 1);
        assertEq(vault.rewardReserve(), 0);
        vm.warp(start + DURATION);
        vm.prank(bob);
        vault.unstake(100 ether);
        vm.prank(alice);
        vault.unstake(1);
        assertEq(token.balanceOf(address(vault)), 10_000 ether);
        assertEq(vault.earned(alice), 0);
    }

    function test_otherWalletCannotWithdrawOrClaimAnotherWalletsFunds() public {
        _stake(alice, 100 ether);
        _fund(DURATION);
        vm.warp(start + DURATION);
        vm.startPrank(bob);
        vm.expectRevert(StakingVault.InsufficientStake.selector);
        vault.unstake(100 ether);
        vm.expectRevert(StakingVault.NoRewards.selector);
        vault.claim();
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.earned(alice), DURATION);
    }

    function test_aprReflectsActiveRateAndStake() public {
        assertEq(vault.aprBps(), 0);
        _fund(DURATION * 1 ether);
        assertEq(vault.aprBps(), 0);
        _stake(alice, 100 ether);
        assertEq(vault.aprBps(), 365 days * 100);
        _stake(bob, 100 ether);
        assertEq(vault.aprBps(), 365 days * 50);
        vm.warp(start + DURATION);
        assertEq(vault.aprBps(), 0);
    }

    function testFuzz_weightedDistributionNeverPaysPrincipal(uint256 a, uint256 b, uint256 rate, uint256 elapsed)
        public
    {
        a = bound(a, 1, 1_000_000 ether);
        b = bound(b, 1, 1_000_000 ether);
        rate = bound(rate, 1, 10 ether);
        elapsed = bound(elapsed, 1, DURATION);
        _stake(alice, a);
        _stake(bob, b);
        _fund(rate * DURATION);
        vm.warp(start + elapsed);
        uint256 earnedA = vault.earned(alice);
        uint256 earnedB = vault.earned(bob);
        uint256 emission = rate * elapsed;
        assertApproxEqAbs(earnedA, emission * a / (a + b), 1);
        assertApproxEqAbs(earnedB, emission * b / (a + b), 1);
        assertLe(earnedA + earnedB, emission);
        if (earnedA > 0) {
            vm.prank(alice);
            vault.claim();
        }
        if (earnedB > 0) {
            vm.prank(bob);
            vault.claim();
        }
        assertEq(token.balanceOf(address(vault)), vault.totalStaked() + vault.rewardReserve());
        vm.warp(start + DURATION);
        vm.prank(alice);
        vault.unstake(a);
        vm.prank(bob);
        vault.unstake(b);
        assertEq(vault.totalStaked(), 0);
    }
}
