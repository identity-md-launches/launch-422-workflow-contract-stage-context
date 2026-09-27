// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LocalDemo} from "../script/LocalDemo.s.sol";
import {AgentArcade} from "../src/AgentArcade.sol";

/// @dev Exercises the local-demo deployment function directly, with explicit configuration and no
/// dependence on the environment or on which address runs the script.
contract LocalDemoTest is Test {
    LocalDemo demo;
    address player = makeAddr("player");

    function setUp() public {
        demo = new LocalDemo();
    }

    function _config() internal view returns (LocalDemo.Config memory cfg) {
        uint256[] memory backings = new uint256[](3);
        backings[0] = 10e18;
        backings[1] = 20e18;
        backings[2] = 30e18;
        address[] memory players = new address[](1);
        players[0] = player;
        cfg = LocalDemo.Config({
            sponsor: address(demo),
            feeRecipient: address(demo),
            epochBackings: backings,
            players: players,
            playerFunding: 1_000e18
        });
    }

    function test_deployWiresEverythingAndFundsEpoch() public {
        LocalDemo.Deployment memory d = demo.deploy(_config());

        assertEq(d.token.totalSupply(), 1e24);
        assertEq(address(d.arcade.token()), address(d.token));
        assertEq(d.arcade.sponsor(), address(demo));
        assertEq(address(d.arcade.vrfCoordinator()), address(d.vrf));
        assertEq(d.epochId, 1);
        assertEq(d.arcade.unsoldBacking(), 60e18);
        assertEq(d.token.balanceOf(address(d.arcade)), 60e18);
        assertEq(d.token.balanceOf(player), 1_000e18);
        assertEq(d.token.balanceOf(address(demo)), 1e24 - 60e18 - 1_000e18);
    }

    function test_demoRoundTripWithMockRandomness() public {
        LocalDemo.Deployment memory d = demo.deploy(_config());
        AgentArcade arcade = d.arcade;

        vm.prank(player);
        d.token.approve(address(arcade), type(uint256).max);
        (uint256 price,,,,,, uint32 version,) = arcade.quote(1);
        vm.prank(player);
        uint256 drawId = arcade.draw(1, version, price);

        // The mock lets the operator pick the word; this is a demo, not randomness.
        d.vrf.fulfill(arcade.drawInfo(drawId).requestId, 2);
        arcade.settle(drawId);
        arcade.deliver(drawId);
        uint256 packId = arcade.drawInfo(drawId).packId;
        assertEq(arcade.ownerOf(packId), player);
        assertEq(arcade.packBacking(packId), 30e18);

        vm.prank(player);
        arcade.redeem(packId);
        assertEq(d.token.balanceOf(player), 1_000e18 - price + 30e18);
    }

    function test_deployWithoutEpochSkipsFunding() public {
        LocalDemo.Config memory cfg = _config();
        cfg.epochBackings = new uint256[](0);
        LocalDemo.Deployment memory d = demo.deploy(cfg);
        assertEq(d.epochId, 0);
        assertEq(d.arcade.epochCount(), 0);
        assertEq(d.token.balanceOf(address(d.arcade)), 0);
    }
}
