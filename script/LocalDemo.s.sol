// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {AgentArcade} from "../src/AgentArcade.sol";
import {MockVRFCoordinator} from "../test/mocks/MockVRFCoordinator.sol";

/// @title LocalDemo — LOCAL DEMO ONLY
/// @notice Deploys WFD, a mock VRF coordinator and the arcade to a local chain (anvil) and funds one epoch,
/// so the frontend can be exercised end to end without Sepolia. The mock coordinator is NOT randomness;
/// whoever calls `MockVRFCoordinator.fulfill` chooses the outcome. Never use this on a public network.
///
/// The Sepolia launch does not use this script: the ProjectFactory deploys LaunchToken and AgentArcade
/// from launch.json. This script exists only to give the site a labelled local demo target.
contract LocalDemo is Script {
    struct Config {
        address sponsor;
        address feeRecipient;
        uint256[] epochBackings;
        address[] players;
        uint256 playerFunding;
    }

    struct Deployment {
        LaunchToken token;
        MockVRFCoordinator vrf;
        AgentArcade arcade;
        uint256 epochId;
    }

    uint32 public constant DEMO_CALLBACK_GAS = 100_000;
    uint16 public constant DEMO_CONFIRMATIONS = 3;

    /// @dev Broadcasts from whatever account forge is given (`--private-key` or `--unlocked`). That account
    /// becomes sponsor and fee recipient for the demo and receives the entire WFD supply.
    function run() external {
        vm.startBroadcast();
        address self = msg.sender;
        uint256[] memory backings = new uint256[](6);
        backings[0] = 10e18;
        backings[1] = 10e18;
        backings[2] = 25e18;
        backings[3] = 50e18;
        backings[4] = 100e18;
        backings[5] = 250e18;
        Config memory cfg = Config({
            sponsor: self, feeRecipient: self, epochBackings: backings, players: new address[](0), playerFunding: 0
        });
        deploy(cfg);
        vm.stopBroadcast();
    }

    /// @notice Deploys everything and creates the first epoch. Callable directly from tests.
    /// @dev The account executing this function must be `cfg.sponsor`: under `run()` that is the
    /// broadcasting account, and when a test calls `deploy` directly it is this script contract. The
    /// executing account receives the WFD supply and funds the first epoch from it.
    function deploy(Config memory cfg) public returns (Deployment memory d) {
        d.token = new LaunchToken();
        d.vrf = new MockVRFCoordinator();
        d.arcade = new AgentArcade(
            address(d.token),
            cfg.sponsor,
            cfg.feeRecipient,
            address(d.vrf),
            1,
            keccak256("local-demo-lane"),
            DEMO_CALLBACK_GAS,
            DEMO_CONFIRMATIONS,
            false
        );

        for (uint256 i; i < cfg.players.length; ++i) {
            d.token.transfer(cfg.players[i], cfg.playerFunding);
        }

        if (cfg.epochBackings.length != 0) {
            uint256 total;
            for (uint256 i; i < cfg.epochBackings.length; ++i) {
                total += cfg.epochBackings[i];
            }
            d.token.approve(address(d.arcade), total);
            d.epochId = d.arcade.createEpoch(cfg.epochBackings);
        }
    }
}
