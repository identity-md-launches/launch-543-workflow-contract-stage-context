// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

contract VaultHandler is Test {
    LaunchToken public token;
    StakingVault public vault;
    address[4] public actors;
    uint256 public funded;
    uint256 public paid;
    uint256 public donated;

    constructor(LaunchToken token_, StakingVault vault_) {
        token = token_;
        vault = vault_;
        actors = [address(0xA), address(0xB), address(0xC), address(0xD)];
        token.approve(address(vault), 1e27);
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            token.approve(address(vault), 1e27);
        }
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        uint256 wallet = token.balanceOf(actor);
        if (wallet == 0) return;
        amount = bound(amount, 1, wallet);
        vm.prank(actor);
        vault.stake(amount);
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        uint256 stakeAmount = vault.balanceOf(actor);
        if (stakeAmount == 0 || block.timestamp < vault.unlockTime(actor)) return;
        amount = bound(amount, 1, stakeAmount);
        vm.prank(actor);
        vault.unstake(amount);
    }

    function claim(uint256 actorSeed) external {
        _claim(actors[actorSeed % 4]);
    }

    function fund(uint256 amount) external {
        uint256 wallet = token.balanceOf(address(this));
        uint256 minimum = block.timestamp >= vault.periodFinish() ? 7 days : 1;
        if (wallet < minimum) return;
        amount = bound(amount, minimum, wallet);
        funded += amount;
        vault.fundRewards(amount);
    }

    function advance(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 10 days));
    }

    function restart() external {
        if (block.timestamp < vault.periodFinish() || vault.unallocatedRewards() < 7 days) return;
        vault.restartRewards();
    }

    function donate(uint256 amount) external {
        uint256 wallet = token.balanceOf(address(this));
        if (wallet == 0) return;
        amount = bound(amount, 1, wallet);
        donated += amount;
        token.transfer(address(vault), amount);
    }

    function closeAll() external {
        // Every principal lock and any current reward period expires within seven days.
        vm.warp(block.timestamp + 7 days);
        for (uint256 i; i < actors.length; ++i) {
            uint256 amount = vault.balanceOf(actors[i]);
            if (amount > 0) {
                vm.prank(actors[i]);
                vault.unstake(amount);
            }
            _claim(actors[i]);
        }
    }

    function _claim(address actor) private {
        if (vault.earned(actor) == 0) return;
        vm.prank(actor);
        paid += vault.claim();
    }
}

contract StakingVaultInvariantTest is Test {
    LaunchToken internal token;
    StakingVault internal vault;
    VaultHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        vault = new StakingVault(address(token));
        handler = new VaultHandler(token, vault);
        token.transfer(address(handler), 5e26);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 1e25);
        }
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.fund.selector;
        selectors[4] = handler.advance.selector;
        selectors[5] = handler.restart.selector;
        selectors[6] = handler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_principalAndRewardLiabilitiesAlwaysBacked() public view {
        uint256 principal;
        uint256 claimable;
        uint256 supply =
            token.balanceOf(address(this)) + token.balanceOf(address(handler)) + token.balanceOf(address(vault));
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            principal += vault.balanceOf(actor);
            claimable += vault.earned(actor);
            supply += token.balanceOf(actor);
            assertLt(vault.rewardRemainder(actor), vault.PRECISION());
        }
        uint256 future =
            block.timestamp < vault.periodFinish() ? (vault.periodFinish() - block.timestamp) * vault.rewardRate() : 0;
        assertEq(principal, vault.totalStaked());
        assertEq(token.balanceOf(address(vault)), principal + vault.rewardReserve() + handler.donated());
        assertEq(vault.rewardReserve(), handler.funded() - handler.paid());
        assertLe(claimable + future + vault.unallocatedRewards(), vault.rewardReserve());
        assertEq(supply, 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function afterInvariant() public {
        handler.closeAll();
        assertEq(vault.totalStaked(), 0, "every actor recovers all principal");
        for (uint256 i; i < 4; ++i) {
            assertGe(token.balanceOf(handler.actors(i)), 1e25);
            assertEq(vault.earned(handler.actors(i)), 0);
        }
        assertEq(token.balanceOf(address(vault)), vault.rewardReserve() + handler.donated());
    }
}
