// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {StakingVault} from "src/StakingVault.sol";

/// @dev Tracks cash flows from successful calls, independently of the vault's account mappings.
/// The reward oracle integrates each wallet's pro-rata share directly; it has no reward index,
/// user checkpoint, or copy of the implementation's remainder algorithm.
contract StakingCashFlowHandler is Test {
    uint256 public constant INITIAL = 25e25;
    uint256 public constant SCALE = 1e36;
    uint256 internal constant D = 7 days;
    LaunchToken public immutable token;
    StakingVault public immutable vault;
    address[4] public actors = [address(0x101), address(0x102), address(0x103), address(0x104)];
    uint256[4] public deposited;
    uint256[4] public withdrawn;
    uint256[4] public paid;
    uint256[4] public funded;
    uint256[4] public donated;
    uint256[4] public expectedUnlock;
    uint256[4] public idealRewardScaled;
    uint256 public modelTime;
    uint256 public stakeCalls;
    uint256 public fundingCalls;
    uint256 public withdrawalCalls;
    uint256 public claimCalls;
    uint256 public rejectedCalls;

    constructor(LaunchToken token_, StakingVault vault_) {
        token = token_;
        vault = vault_;
        modelTime = block.timestamp;
        for (uint256 i; i < 4; ++i) {
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function principal(uint256 i) public view returns (uint256) {
        return deposited[i] - withdrawn[i];
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        uint256 i = actorSeed % 4;
        uint256 wallet = token.balanceOf(actors[i]);
        if (wallet == 0) return;
        amount = bound(amount, 1, wallet);
        _integrate();
        vm.prank(actors[i]);
        vault.stake(amount);
        deposited[i] += amount;
        expectedUnlock[i] = block.timestamp + D;
        stakeCalls++;
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        uint256 i = actorSeed % 4;
        uint256 balance = principal(i);
        if (balance == 0 || block.timestamp < expectedUnlock[i]) return;
        _integrate();
        _withdraw(i, bound(amount, 1, balance));
    }

    function claim(uint256 actorSeed) external {
        _integrate();
        _claim(actorSeed % 4);
    }

    function fund(uint256 actorSeed, uint256 amount) external {
        uint256 i = actorSeed % 4;
        uint256 wallet = token.balanceOf(actors[i]);
        uint256 minimum = block.timestamp < vault.periodFinish() ? 1 : D;
        if (wallet < minimum) return;
        amount = bound(amount, minimum, wallet);
        _integrate();
        uint256 finish = vault.periodFinish();
        uint256 rate = vault.rewardRate();
        vm.prank(actors[i]);
        vault.fundRewards(amount);
        funded[i] += amount;
        fundingCalls++;
        if (block.timestamp < finish) {
            assertEq(vault.periodFinish(), finish, "top-up postponed existing rewards");
            assertGe(vault.rewardRate(), rate, "top-up reduced the rate");
        } else {
            assertEq(vault.periodFinish(), block.timestamp + D);
        }
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        uint256 i = actorSeed % 4;
        uint256 wallet = token.balanceOf(actors[i]);
        if (wallet == 0) return;
        amount = bound(amount, 1, wallet);
        vm.prank(actors[i]);
        assertTrue(token.transfer(address(vault), amount));
        donated[i] += amount;
    }

    function advance(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 9 days));
        _integrate();
    }

    function restart(uint256 actorSeed) external {
        _integrate();
        if (block.timestamp < vault.periodFinish()) {
            vm.prank(actors[actorSeed % 4]);
            vm.expectRevert(StakingVault.ActiveRewardPeriod.selector);
            vault.restartRewards();
            rejectedCalls++;
        } else if (vault.unallocatedRewards() < D) {
            vm.prank(actors[actorSeed % 4]);
            vm.expectRevert(StakingVault.InsufficientRewardFunding.selector);
            vault.restartRewards();
            rejectedCalls++;
        } else {
            vm.prank(actors[actorSeed % 4]);
            vault.restartRewards();
            assertEq(vault.periodFinish(), block.timestamp + D);
        }
    }

    function rejectWithdrawal(uint256 actorSeed) external {
        uint256 i = actorSeed % 4;
        uint256 balance = principal(i);
        vm.prank(actors[i]);
        if (balance > 0 && block.timestamp < expectedUnlock[i]) {
            vm.expectRevert(abi.encodeWithSelector(StakingVault.StakeLocked.selector, expectedUnlock[i]));
            vault.unstake(1);
        } else {
            vm.expectRevert(StakingVault.InsufficientStake.selector);
            vault.unstake(balance + 1);
        }
        rejectedCalls++;
    }

    function rejectUnapprovedStake(uint256 actorSeed) external {
        uint256 i = actorSeed % 4;
        vm.startPrank(actors[i]);
        token.approve(address(vault), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.stake(1);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        rejectedCalls++;
    }

    /// @dev Only called by afterInvariant, never selected for random dispatch.
    function settle() external {
        vm.warp(block.timestamp + D);
        _integrate();
        for (uint256 i; i < 4; ++i) {
            uint256 balance = principal(i);
            if (balance != 0) _withdraw(i, balance);
            _claim(i);
        }
    }

    function _withdraw(uint256 i, uint256 amount) internal {
        uint256 beforeBalance = token.balanceOf(actors[i]);
        vm.prank(actors[i]);
        vault.unstake(amount);
        withdrawn[i] += amount;
        if (principal(i) == 0) expectedUnlock[i] = 0;
        assertEq(token.balanceOf(actors[i]) - beforeBalance, amount, "principal paid to wrong wallet");
        withdrawalCalls++;
    }

    function _claim(uint256 i) internal {
        uint256 amount = vault.earned(actors[i]);
        uint256 beforeBalance = token.balanceOf(actors[i]);
        vm.prank(actors[i]);
        if (amount == 0) {
            vm.expectRevert(StakingVault.NoRewards.selector);
            vault.claim();
            rejectedCalls++;
        } else {
            assertEq(vault.claim(), amount, "claim does not match the preview");
            paid[i] += amount;
            assertEq(token.balanceOf(actors[i]) - beforeBalance, amount, "reward paid to wrong wallet");
            claimCalls++;
        }
    }

    function _integrate() internal {
        uint256 end = Math.min(block.timestamp, vault.periodFinish());
        uint256 begin = Math.min(modelTime, vault.periodFinish());
        uint256 emission = (end - begin) * vault.rewardRate();
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            total += principal(i);
        }
        if (total != 0) {
            for (uint256 i; i < 4; ++i) {
                idealRewardScaled[i] += Math.mulDiv(emission * SCALE, principal(i), total);
            }
        }
        modelTime = block.timestamp;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract StakingVaultModelInvariantTest is Test {
    LaunchToken internal token;
    StakingVault internal vault;
    StakingCashFlowHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        vault = new StakingVault(address(token));
        handler = new StakingCashFlowHandler(token, vault);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), handler.INITIAL());
        }
        // Seed a live, unequal-weight schedule so no campaign starts with vacuous accounting.
        handler.stake(0, 1);
        handler.stake(1, 1 ether);
        handler.stake(2, 1e24);
        handler.fund(3, 7 days * 1e12);
        handler.advance(1);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.fund.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.restart.selector;
        selectors[7] = handler.rejectWithdrawal.selector;
        selectors[8] = handler.rejectUnapprovedStake.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_eachWalletRetainsItsPrincipalAndProRataRewards() public view {
        uint256 totalPrincipal;
        uint256 totalFunding;
        uint256 totalPaid;
        uint256 totalDonations;
        uint256 claimable;
        uint256 wallets;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 principal = handler.principal(i);
            uint256 paid = handler.paid(i);
            uint256 funding = handler.funded(i);
            uint256 donations = handler.donated(i);
            uint256 earned = vault.earned(actor);
            assertEq(vault.balanceOf(actor), principal, "position differs from actual deposits minus withdrawals");
            assertEq(vault.unlockTime(actor), handler.expectedUnlock(i), "only own deposits reset the lock");
            assertEq(token.balanceOf(actor) + principal + funding + donations, handler.INITIAL() + paid);
            // Fewer than 256 checkpoints (128 random calls plus setup/settlement), 10^27
            // supply and 10^36 index precision: truncation is <256*10^27/10^36 minor units
            // (<1 wei). The direct oracle's own
            // sub-unit truncation is smaller still. No percentage-based tolerance is used.
            assertApproxEqAbs(paid + earned, handler.idealRewardScaled(i) / handler.SCALE(), 1);
            totalPrincipal += principal;
            totalFunding += funding;
            totalPaid += paid;
            totalDonations += donations;
            claimable += earned;
            wallets += token.balanceOf(actor);
        }
        assertEq(vault.totalStaked(), totalPrincipal);
        assertEq(vault.rewardReserve() + totalPaid, totalFunding);
        assertLe(claimable, vault.rewardReserve());
        assertEq(token.balanceOf(address(vault)), totalPrincipal + vault.rewardReserve() + totalDonations);
        assertEq(wallets + token.balanceOf(address(vault)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function afterInvariant() public {
        handler.settle();
        invariant_eachWalletRetainsItsPrincipalAndProRataRewards();
        assertEq(vault.totalStaked(), 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(handler.deposited(i), handler.withdrawn(i), "all deposited principal must be recoverable");
            assertEq(vault.earned(handler.actors(i)), 0);
        }
    }

    function test_handlerExercisesClaimsExitsAndExpectedFailures() public {
        handler.claim(2);
        handler.rejectWithdrawal(0);
        handler.rejectUnapprovedStake(1);
        handler.advance(7 days);
        handler.unstake(0, 1);
        handler.settle();
        invariant_eachWalletRetainsItsPrincipalAndProRataRewards();
        assertGt(handler.stakeCalls(), 0);
        assertGt(handler.fundingCalls(), 0);
        assertGt(handler.claimCalls(), 0);
        assertGt(handler.withdrawalCalls(), 0);
        assertGt(handler.rejectedCalls(), 0);
    }
}
