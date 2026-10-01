// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @dev Intentionally hostile token for exercising defenses; never used in deployment.
contract FaultToken is ERC20 {
    StakingVault public vault;
    bool public failTransfers;
    bool public chargeFee;
    bool public callbacks;
    uint256 public blockedCallbacks;

    constructor() ERC20("Fault", "FAULT") {
        _mint(msg.sender, 1e27);
    }

    function configure(StakingVault vault_, bool fail_, bool fee_, bool callbacks_) external {
        vault = vault_;
        failTransfers = fail_;
        chargeFee = fee_;
        callbacks = callbacks_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        if (callbacks && msg.sender == address(vault)) _attack();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        if (callbacks && msg.sender == address(vault)) _attack();
        if (chargeFee) {
            super.transferFrom(from, to, amount - 1);
            _burn(from, 1);
            return true;
        }
        return super.transferFrom(from, to, amount);
    }

    function _attack() internal {
        bytes[5] memory calls = [
            abi.encodeCall(vault.stake, (1)),
            abi.encodeCall(vault.unstake, (1)),
            abi.encodeCall(vault.claim, ()),
            abi.encodeCall(vault.fundRewards, (1)),
            abi.encodeCall(vault.restartRewards, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory result) = address(vault).call(calls[i]);
            require(!ok && bytes4(result) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "reentry allowed");
            blockedCallbacks++;
        }
    }
}

contract FactoryHarness {
    function deploy() external returns (LaunchToken token, StakingVault vault) {
        token = new LaunchToken();
        vault = new StakingVault(address(token));
    }
}

contract StakingVaultSecurityTest is Test {
    FaultToken internal token;
    StakingVault internal vault;
    uint256 internal constant DURATION = 7 days;

    function setUp() public {
        vm.warp(1_000_000);
        token = new FaultToken();
        vault = new StakingVault(address(token));
        token.approve(address(vault), 1e27);
    }

    function test_reentryThroughAllMutationsBlockedOnEveryTokenInteraction() public {
        token.configure(vault, false, false, true);
        vault.stake(100 ether);
        assertEq(token.blockedCallbacks(), 5);
        vault.fundRewards(DURATION * 1 ether);
        assertEq(token.blockedCallbacks(), 10);
        vm.warp(block.timestamp + DURATION);
        vault.claim();
        assertEq(token.blockedCallbacks(), 15);
        vault.unstake(100 ether);
        assertEq(token.blockedCallbacks(), 20);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_falseReturningTokenRollsBackStakeAndFunding() public {
        token.configure(vault, true, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.stake(100 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.fundRewards(100 ether);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.unlockTime(address(this)), 0);
        assertEq(vault.rewardReserve(), 0);
        assertEq(vault.periodFinish(), 0);
    }

    function test_failedPayoutAndWithdrawalPreserveClaimsAndPrincipalForRetry() public {
        vault.stake(100 ether);
        vault.fundRewards(DURATION * 1 ether);
        vm.warp(block.timestamp + DURATION);
        token.configure(vault, true, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.claim();
        assertEq(vault.earned(address(this)), DURATION * 1 ether);
        assertEq(vault.rewardReserve(), DURATION * 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.unstake(100 ether);
        assertEq(vault.balanceOf(address(this)), 100 ether);
        assertEq(vault.totalStaked(), 100 ether);
        token.configure(vault, false, false, false);
        vault.unstake(100 ether);
        vault.claim();
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_feeOnTransferRejectedWithoutCreditingUnreceivedTokens() public {
        token.configure(vault, false, true, false);
        vm.expectRevert(StakingVault.UnexpectedTokenAmount.selector);
        vault.stake(100 ether);
        vm.expectRevert(StakingVault.UnexpectedTokenAmount.selector);
        vault.fundRewards(100 ether);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.rewardReserve(), 0);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_factoryConstructorCompatibilityRuntimeAndNoAdminEscape() public {
        FactoryHarness factory = new FactoryHarness();
        (LaunchToken launchToken, StakingVault deployed) = factory.deploy();
        assertEq(launchToken.balanceOf(address(factory)), 1e27);
        assertEq(launchToken.balanceOf(address(deployed)), 0);
        assertEq(address(deployed.token()), address(launchToken));
        _checkRuntime(address(launchToken));
        _checkRuntime(address(deployed));
        bytes[5] memory attacks = [
            abi.encodeWithSignature("withdraw(address,uint256)", address(this), 1),
            abi.encodeWithSignature("rescueTokens(address,uint256)", address(launchToken), 1),
            abi.encodeWithSignature("setOwner(address)", address(this)),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("pause()")
        ];
        for (uint256 i; i < attacks.length; ++i) {
            (bool ok,) = address(deployed).call(attacks[i]);
            assertFalse(ok);
        }
    }

    function _checkRuntime(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
    }
}
