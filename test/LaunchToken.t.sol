// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant SUPPLY = 1_000_000 * 1e18;

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Workflow Demo");
        assertEq(token.symbol(), "WFD");
        assertEq(token.decimals(), 18);
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e24);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit LaunchToken.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new LaunchToken();
    }

    function test_transferMovesExactAmount() public {
        uint256 amount = 1234e18;
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit LaunchToken.Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, 1, 0));
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, false, true);
        emit LaunchToken.Approval(deployer, alice, 500e18);
        assertTrue(token.approve(alice, 500e18));
        assertEq(token.allowance(deployer, alice), 500e18);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 200e18));
        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.allowance(deployer, alice), 300e18);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, 101, 100));
        token.transferFrom(deployer, bob, 101);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.approve(address(0), 1);
    }

    /// @dev Mirrors the protected floor: no common admin selector may change supply or credit a caller.
    function test_noAdminSelectorChangesSupply() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
        vm.prank(deployer);
        (bool okDeployer,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", deployer, 1));
        assertFalse(okDeployer);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeHasNoEscapeOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_transferConservesSupply(uint256 amount, address to) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
