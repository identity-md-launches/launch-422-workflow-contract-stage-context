// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {AgentArcade} from "../src/AgentArcade.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

/// @dev Drives the arcade through arbitrary sequences of valid and invalid actions.
contract ArcadeHandler is Test {
    LaunchToken public token;
    AgentArcade public arcade;
    MockVRFCoordinator public vrf;
    address public sponsor;
    address public feeRecipient;
    address[] public players;

    uint256 public ghostFundedBacking; // WFD ever pulled into the arcade as backing
    uint256 public ghostPaidPrices; // WFD ever pulled into the arcade as draw prices
    uint256 public ghostRedeemed; // WFD ever paid out to pack redeemers
    uint256 public ghostWithdrawn; // WFD ever paid out as proceeds
    uint256 public ghostPacksMinted;
    uint256 public ghostPacksRedeemed;

    constructor(LaunchToken token_, AgentArcade arcade_, MockVRFCoordinator vrf_, address sponsor_, address fee_) {
        token = token_;
        arcade = arcade_;
        vrf = vrf_;
        sponsor = sponsor_;
        feeRecipient = fee_;
        players.push(makeAddr("p1"));
        players.push(makeAddr("p2"));
        players.push(makeAddr("p3"));
    }

    function _player(uint256 seed) internal view returns (address) {
        return players[seed % players.length];
    }

    function createEpoch(uint256 seed, uint8 count) external {
        count = uint8(bound(count, 2, 12));
        uint256[] memory b = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            b[i] = (uint256(keccak256(abi.encode(seed, i))) % 5 + 1) * 1e18;
        }
        // Guarantee two distinct values so the call is valid most of the time.
        if (count >= 2) {
            b[1] = b[0] == 1e18 ? 2e18 : 1e18;
        }
        uint256 total;
        for (uint256 i; i < count; ++i) {
            total += b[i];
        }
        vm.prank(sponsor);
        try arcade.createEpoch(b) {
            ghostFundedBacking += total;
        } catch {}
    }

    function draw(uint256 seed) external {
        uint256 epochs = arcade.epochCount();
        if (epochs == 0) return;
        uint256 epochId = seed % epochs + 1;
        (uint256 price,,,,,, uint32 version,) = arcade.quote(epochId);
        address p = _player(seed);
        vm.prank(p);
        try arcade.draw(epochId, version, price) {
            ghostPaidPrices += price;
        } catch {}
    }

    function fulfil(uint256 word) external {
        uint256 pending = arcade.pendingDrawId();
        if (pending == 0) return;
        AgentArcade.Draw memory d = arcade.drawInfo(pending);
        if (d.status != AgentArcade.DrawStatus.Requested) return;
        vrf.fulfill(d.requestId, word);
    }

    function settle() external {
        uint256 pending = arcade.pendingDrawId();
        if (pending == 0) return;
        try arcade.settle(pending) {} catch {}
    }

    function deliver(uint256 seed) external {
        uint256 draws = arcade.drawCount();
        if (draws == 0) return;
        uint256 drawId = seed % draws + 1;
        try arcade.deliver(drawId) {
            ghostPacksMinted += 1;
        } catch {}
    }

    function redeem(uint256 seed) external {
        uint256 packs = arcade.nextPackId();
        if (packs == 0) return;
        uint256 packId = seed % packs + 1;
        address owner;
        try arcade.ownerOf(packId) returns (address o) {
            owner = o;
        } catch {
            return;
        }
        uint256 backing = arcade.packBacking(packId);
        vm.prank(owner);
        try arcade.redeem(packId) {
            ghostRedeemed += backing;
            ghostPacksRedeemed += 1;
        } catch {}
    }

    function transferPack(uint256 seed) external {
        uint256 packs = arcade.nextPackId();
        if (packs == 0) return;
        uint256 packId = seed % packs + 1;
        address owner;
        try arcade.ownerOf(packId) returns (address o) {
            owner = o;
        } catch {
            return;
        }
        vm.prank(owner);
        arcade.transferFrom(owner, _player(seed >> 8), packId);
    }

    function withdraw(bool asSponsor) external {
        address who = asSponsor ? sponsor : feeRecipient;
        uint256 amount = arcade.withdrawable(who);
        vm.prank(who);
        try arcade.withdrawPayments() {
            ghostWithdrawn += amount;
        } catch {}
    }

    function sweep(uint256 seed) external {
        uint256 epochs = arcade.epochCount();
        if (epochs == 0) return;
        uint256 epochId = seed % epochs + 1;
        uint256 remaining = arcade.epochInfo(epochId).remainingCount;
        vm.prank(sponsor);
        try arcade.sweepEpoch(epochId) {
            ghostPacksMinted += remaining;
        } catch {}
    }

    function togglePause(bool on) external {
        vm.prank(sponsor);
        arcade.setPaused(on);
    }
}

contract AgentArcadeInvariantTest is Test {
    LaunchToken token;
    AgentArcade arcade;
    MockVRFCoordinator vrf;
    ArcadeHandler handler;

    address sponsor = makeAddr("sponsor");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        token = new LaunchToken();
        vrf = new MockVRFCoordinator();
        arcade = new AgentArcade(
            address(token), sponsor, feeRecipient, address(vrf), 1, keccak256("lane"), 100_000, 3, false
        );
        handler = new ArcadeHandler(token, arcade, vrf, sponsor, feeRecipient);

        token.transfer(sponsor, 100_000_000e18);
        vm.prank(sponsor);
        token.approve(address(arcade), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            address p = handler.players(i);
            token.transfer(p, 100_000_000e18);
            vm.prank(p);
            token.approve(address(arcade), type(uint256).max);
        }

        targetContract(address(handler));
    }

    /// @notice The arcade always holds exactly what it owes: unsold + reserved + minted backing + proceeds.
    function invariant_balanceEqualsLiabilities() public view {
        assertEq(token.balanceOf(address(arcade)), arcade.totalLiabilities());
        assertEq(arcade.surplus(), 0);
    }

    /// @notice Every WFD that entered is either still owed or has been paid out to exactly who earned it.
    function invariant_flowsReconcile() public view {
        uint256 inflow = handler.ghostFundedBacking() + handler.ghostPaidPrices();
        uint256 outflow = handler.ghostRedeemed() + handler.ghostWithdrawn();
        assertEq(inflow, outflow + arcade.totalLiabilities());
        assertEq(
            handler.ghostFundedBacking(),
            arcade.unsoldBacking() + arcade.reservedBacking() + arcade.mintedBacking() + handler.ghostRedeemed()
        );
        assertEq(handler.ghostPaidPrices(), arcade.totalWithdrawable() + handler.ghostWithdrawn());
    }

    /// @notice Fee and sponsor shares always sum to the proceeds pool.
    function invariant_proceedsSplit() public view {
        assertEq(arcade.withdrawable(sponsor) + arcade.withdrawable(feeRecipient), arcade.totalWithdrawable());
    }

    /// @notice At most one draw is ever pending, and a pending draw is never already settled.
    function invariant_singlePendingDraw() public view {
        uint256 pending = arcade.pendingDrawId();
        uint256 draws = arcade.drawCount();
        for (uint256 i = 1; i <= draws; ++i) {
            AgentArcade.DrawStatus s = arcade.drawInfo(i).status;
            bool unsettled = s == AgentArcade.DrawStatus.Requested || s == AgentArcade.DrawStatus.Fulfilled;
            if (unsettled) assertEq(pending, i, "unsettled draw is not the pending one");
        }
        if (pending != 0) {
            AgentArcade.DrawStatus s = arcade.drawInfo(pending).status;
            assertTrue(s == AgentArcade.DrawStatus.Requested || s == AgentArcade.DrawStatus.Fulfilled);
        }
    }

    /// @notice Per-epoch bookkeeping matches the stored inventory, and closed epochs really lack variety.
    function invariant_epochInventoryConsistent() public view {
        uint256 epochs = arcade.epochCount();
        uint256 unsold;
        for (uint256 e = 1; e <= epochs; ++e) {
            AgentArcade.Epoch memory info = arcade.epochInfo(e);
            uint256[] memory remaining = arcade.remainingPackBackings(e);
            assertEq(remaining.length, info.remainingCount);
            uint256 sum;
            uint256 distinct;
            for (uint256 i; i < remaining.length; ++i) {
                sum += remaining[i];
                bool seen;
                for (uint256 j; j < i; ++j) {
                    if (remaining[j] == remaining[i]) seen = true;
                }
                if (!seen) ++distinct;
            }
            assertEq(sum, info.remainingBacking);
            assertEq(distinct, info.distinctValues);
            if (info.drawsOpen) assertGe(distinct, 2);
            else assertLt(distinct, 2);
            unsold += sum;
        }
        assertEq(unsold, arcade.unsoldBacking());
    }

    /// @notice Minted, unredeemed packs are exactly the minted backing.
    function invariant_packLedger() public view {
        uint256 packs = arcade.nextPackId();
        uint256 live;
        uint256 liveBacking;
        for (uint256 p = 1; p <= packs; ++p) {
            try arcade.ownerOf(p) returns (address) {
                ++live;
                liveBacking += arcade.packBacking(p);
            } catch {}
        }
        assertEq(live, handler.ghostPacksMinted() - handler.ghostPacksRedeemed());
        assertEq(liveBacking, arcade.mintedBacking());
    }
}
