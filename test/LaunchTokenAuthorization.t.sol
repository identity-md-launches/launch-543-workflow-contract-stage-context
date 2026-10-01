// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract LaunchTokenAuthorizationTest is Test {
    LaunchToken internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fullSupplySelfTransferDoesNotCreateOrDestroyTokens() public {
        assertTrue(token.transfer(address(this), 1e27));
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_zeroTransferFromNeedsNoApprovalAndMovesNothing() public {
        vm.prank(BOB);
        assertTrue(token.transferFrom(address(this), ALICE, 0));
        assertEq(token.allowance(address(this), BOB), 0);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromToZeroRollsBackAllowance() public {
        token.approve(BOB, 7);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 7);
        assertEq(token.allowance(address(this), BOB), 7);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_insufficientBalanceDoesNotConsumeFiniteApproval() public {
        vm.prank(ALICE);
        token.approve(BOB, 10);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10));
        token.transferFrom(ALICE, BOB, 10);
        assertEq(token.allowance(ALICE, BOB), 10);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_approvalReplacementDoesNotAddToOldAllowance() public {
        token.approve(BOB, 10);
        token.approve(BOB, 4);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 4, 5));
        token.transferFrom(address(this), BOB, 5);
        assertEq(token.allowance(address(this), BOB), 4);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_zeroSpenderAndZeroSourceCannotAuthorizeTransfers() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.prank(BOB);
        // The vendored ERC-20 validates the allowance owner before attempting the transfer.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_infiniteApprovalSurvivesSpendingButCanBeRevoked(uint256 amount) public {
        amount = bound(amount, 1, 1e27);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, amount / 2);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
        vm.prank(ALICE);
        token.approve(BOB, 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceOf(ALICE), amount - amount / 2);
        assertEq(token.balanceOf(BOB), amount / 2);
        assertEq(token.totalSupply(), 1e27);
    }
}

contract TokenAuthorizationHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors = [address(0x201), address(0x202), address(0x203), address(0x204)];
    uint256[4] public expectedBalance;
    uint256[4][4] public expectedAllowance;

    constructor(LaunchToken token_) {
        token = token_;
        for (uint256 i; i < 4; ++i) {
            expectedBalance[i] = 25e25;
            uint256 spender = (i + 1) % 4;
            vm.prank(actors[i]);
            token.approve(actors[spender], type(uint256).max);
            expectedAllowance[i][spender] = type(uint256).max;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        amount = unlimited ? type(uint256).max : bound(amount, 0, 1e27);
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        amount = bound(amount, 0, expectedBalance[from] + 1);
        vm.prank(actors[from]);
        if (amount > expectedBalance[from]) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, actors[from], expectedBalance[from], amount
                )
            );
            token.transfer(actors[to], amount);
        } else {
            assertTrue(token.transfer(actors[to], amount));
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        amount = bound(amount, 0, expectedBalance[owner] + 1);
        uint256 allowance = expectedAllowance[owner][spender];
        vm.prank(actors[spender]);
        if (amount > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], allowance, amount
                )
            );
            token.transferFrom(actors[owner], actors[to], amount);
        } else if (amount > expectedBalance[owner]) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, actors[owner], expectedBalance[owner], amount
                )
            );
            token.transferFrom(actors[owner], actors[to], amount);
        } else {
            assertTrue(token.transferFrom(actors[owner], actors[to], amount));
            expectedBalance[owner] -= amount;
            expectedBalance[to] += amount;
            if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenAuthorizationInvariantTest is Test {
    LaunchToken internal token;
    TokenAuthorizationHandler internal handler;

    function setUp() public {
        token = new LaunchToken();
        handler = new TokenAuthorizationHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 25e25);
        }
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.transferFrom.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesAndAllowancesMatchAuthorizedTransfers() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(i), "unauthorized balance change");
            sum += token.balanceOf(actor);
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(actor, handler.actors(j)), handler.expectedAllowance(i, j));
            }
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
