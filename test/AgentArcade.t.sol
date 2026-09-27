// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {AgentArcade, IERC721Receiver} from "../src/AgentArcade.sol";
import {VRFV2PlusExtraArgs} from "../src/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

/// @dev Accepts ERC-721 safe transfers.
contract Receiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Rejects ERC-721 safe transfers; must still be able to receive a delivered prize.
contract Rejecter is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(0);
    }
}

/// @dev Tries to redeem a pack twice from inside the ERC-721 receive hook.
contract DoubleRedeemer is IERC721Receiver {
    AgentArcade immutable arcade;
    bool public secondRedeemFailed;

    constructor(AgentArcade arcade_) {
        arcade = arcade_;
    }

    function onERC721Received(address, address, uint256 packId, bytes calldata) external returns (bytes4) {
        arcade.redeem(packId);
        (bool ok,) = address(arcade).call(abi.encodeCall(AgentArcade.redeem, (packId)));
        secondRedeemFailed = !ok;
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract AgentArcadeTest is Test {
    LaunchToken token;
    MockVRFCoordinator vrf;
    AgentArcade arcade;

    address factory = makeAddr("factory");
    address sponsor = makeAddr("sponsor");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint256 constant SUB_ID = 7777;
    bytes32 constant KEY_HASH = keccak256("sepolia-lane");
    uint32 constant CALLBACK_GAS = 100_000;
    uint16 constant CONFIRMATIONS = 3;

    function setUp() public {
        vm.prank(factory);
        token = new LaunchToken();
        vrf = new MockVRFCoordinator();
        vm.prank(factory);
        arcade = new AgentArcade(
            address(token), sponsor, feeRecipient, address(vrf), SUB_ID, KEY_HASH, CALLBACK_GAS, CONFIRMATIONS, true
        );

        vm.startPrank(factory);
        token.transfer(sponsor, 100_000e18);
        token.transfer(alice, 100_000e18);
        token.transfer(bob, 100_000e18);
        vm.stopPrank();

        vm.prank(sponsor);
        token.approve(address(arcade), type(uint256).max);
        vm.prank(alice);
        token.approve(address(arcade), type(uint256).max);
        vm.prank(bob);
        token.approve(address(arcade), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _backings4() internal pure returns (uint256[] memory b) {
        b = new uint256[](4);
        b[0] = 100e18;
        b[1] = 100e18;
        b[2] = 300e18;
        b[3] = 500e18;
    }

    function _createEpoch(uint256[] memory backings) internal returns (uint256 id) {
        vm.prank(sponsor);
        id = arcade.createEpoch(backings);
    }

    function _price(uint256 epochId) internal view returns (uint256 price, uint32 version) {
        (price,,,,,, version,) = arcade.quote(epochId);
    }

    /// @dev Full happy path: request → fulfil → settle → deliver. Returns the draw id and pack id.
    function _play(address buyer, uint256 epochId, uint256 randomness)
        internal
        returns (uint256 drawId, uint256 packId)
    {
        (uint256 price, uint32 version) = _price(epochId);
        vm.prank(buyer);
        drawId = arcade.draw(epochId, version, price);
        vrf.fulfill(arcade.drawInfo(drawId).requestId, randomness);
        vm.prank(keeper);
        arcade.settle(drawId);
        vm.prank(keeper);
        arcade.deliver(drawId);
        packId = arcade.drawInfo(drawId).packId;
    }

    function _assertSolvent() internal view {
        assertEq(token.balanceOf(address(arcade)), arcade.totalLiabilities(), "balance != liabilities");
        assertEq(arcade.surplus(), 0);
    }

    // ------------------------------------------------------------------ constructor

    function test_constructorStoresConfig() public view {
        assertEq(address(arcade.token()), address(token));
        assertEq(arcade.sponsor(), sponsor);
        assertEq(arcade.feeRecipient(), feeRecipient);
        assertEq(address(arcade.vrfCoordinator()), address(vrf));
        assertEq(arcade.vrfSubscriptionId(), SUB_ID);
        assertEq(arcade.vrfKeyHash(), KEY_HASH);
        assertEq(arcade.vrfCallbackGasLimit(), CALLBACK_GAS);
        assertEq(arcade.vrfRequestConfirmations(), CONFIRMATIONS);
        assertTrue(arcade.vrfNativePayment());
        assertFalse(arcade.paused());
        assertEq(arcade.FEE_BPS(), 500);
    }

    function test_constructorDoesNotTouchTokenBalances() public {
        uint256 before = token.balanceOf(factory);
        vm.prank(factory);
        new AgentArcade(address(token), sponsor, feeRecipient, address(vrf), SUB_ID, KEY_HASH, CALLBACK_GAS, 3, false);
        assertEq(token.balanceOf(factory), before);
        assertEq(token.totalSupply(), 1e24);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(AgentArcade.ZeroAddress.selector);
        new AgentArcade(address(0), sponsor, feeRecipient, address(vrf), SUB_ID, KEY_HASH, CALLBACK_GAS, 3, true);
        vm.expectRevert(AgentArcade.ZeroAddress.selector);
        new AgentArcade(address(token), address(0), feeRecipient, address(vrf), SUB_ID, KEY_HASH, CALLBACK_GAS, 3, true);
        vm.expectRevert(AgentArcade.ZeroAddress.selector);
        new AgentArcade(address(token), sponsor, address(0), address(vrf), SUB_ID, KEY_HASH, CALLBACK_GAS, 3, true);
        vm.expectRevert(AgentArcade.ZeroAddress.selector);
        new AgentArcade(address(token), sponsor, feeRecipient, address(0), SUB_ID, KEY_HASH, CALLBACK_GAS, 3, true);
    }

    function test_constructorRejectsInvalidVrfConfig() public {
        vm.expectRevert(AgentArcade.InvalidConfig.selector);
        new AgentArcade(address(token), sponsor, feeRecipient, address(vrf), SUB_ID, bytes32(0), CALLBACK_GAS, 3, true);
        vm.expectRevert(AgentArcade.InvalidConfig.selector);
        new AgentArcade(address(token), sponsor, feeRecipient, address(vrf), SUB_ID, KEY_HASH, 0, 3, true);
        vm.expectRevert(AgentArcade.InvalidConfig.selector);
        new AgentArcade(address(token), sponsor, feeRecipient, address(vrf), SUB_ID, KEY_HASH, CALLBACK_GAS, 0, true);
        vm.expectRevert(AgentArcade.InvalidConfig.selector);
        new AgentArcade(address(token), sponsor, feeRecipient, address(vrf), 0, KEY_HASH, CALLBACK_GAS, 3, true);
    }

    // ------------------------------------------------------------------ epochs

    function test_createEpochPullsBackingAndRecordsInventory() public {
        uint256[] memory b = _backings4();
        uint256 sponsorBefore = token.balanceOf(sponsor);

        vm.expectEmit(true, false, false, true);
        emit AgentArcade.EpochCreated(1, b, 1000e18);
        uint256 id = _createEpoch(b);

        assertEq(id, 1);
        assertEq(arcade.epochCount(), 1);
        assertEq(token.balanceOf(sponsor), sponsorBefore - 1000e18);
        assertEq(token.balanceOf(address(arcade)), 1000e18);
        assertEq(arcade.unsoldBacking(), 1000e18);

        AgentArcade.Epoch memory e = arcade.epochInfo(id);
        assertEq(e.packCount, 4);
        assertEq(e.remainingCount, 4);
        assertEq(e.distinctValues, 3);
        assertTrue(e.drawsOpen);
        assertFalse(e.swept);
        assertEq(e.totalBacking, 1000e18);
        assertEq(e.remainingBacking, 1000e18);
        assertEq(e.version, 0);
        assertEq(e.createdAt, block.timestamp);

        uint256[] memory remaining = arcade.remainingPackBackings(id);
        assertEq(remaining.length, 4);
        assertEq(remaining[3], 500e18);
        _assertSolvent();
    }

    function test_createEpochOnlySponsor() public {
        vm.prank(alice);
        vm.expectRevert(AgentArcade.NotSponsor.selector);
        arcade.createEpoch(_backings4());
    }

    function test_createEpochRejectsBadPackCounts() public {
        uint256[] memory one = new uint256[](1);
        one[0] = 1e18;
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.InvalidPackCount.selector, 1));
        arcade.createEpoch(one);

        uint256[] memory none = new uint256[](0);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.InvalidPackCount.selector, 0));
        arcade.createEpoch(none);

        uint256[] memory tooMany = new uint256[](65);
        for (uint256 i; i < 65; ++i) {
            tooMany[i] = i + 1;
        }
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.InvalidPackCount.selector, 65));
        arcade.createEpoch(tooMany);
    }

    function test_createEpochAllowsSixtyFourPacks() public {
        uint256[] memory b = new uint256[](64);
        for (uint256 i; i < 64; ++i) {
            b[i] = (i % 4 + 1) * 1e18;
        }
        uint256 id = _createEpoch(b);
        assertEq(arcade.epochInfo(id).remainingCount, 64);
        assertEq(arcade.epochInfo(id).distinctValues, 4);
    }

    function test_createEpochRejectsZeroBacking() public {
        uint256[] memory b = _backings4();
        b[2] = 0;
        vm.prank(sponsor);
        vm.expectRevert(AgentArcade.ZeroBacking.selector);
        arcade.createEpoch(b);
    }

    function test_createEpochRejectsSingleDistinctValue() public {
        uint256[] memory b = new uint256[](3);
        b[0] = 5e18;
        b[1] = 5e18;
        b[2] = 5e18;
        vm.prank(sponsor);
        vm.expectRevert(AgentArcade.InsufficientVariety.selector);
        arcade.createEpoch(b);
    }

    function test_createEpochFailsWithoutSponsorFunds() public {
        uint256 sponsorBalance = token.balanceOf(sponsor);
        vm.prank(sponsor);
        token.transfer(alice, sponsorBalance);
        assertEq(token.balanceOf(sponsor), 0);
        vm.prank(sponsor);
        vm.expectRevert();
        arcade.createEpoch(_backings4());
        assertEq(arcade.epochCount(), 0);
    }

    function test_unknownEpochReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.UnknownEpoch.selector, 0));
        arcade.quote(0);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.UnknownEpoch.selector, 1));
        arcade.epochInfo(1);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.UnknownEpoch.selector, 3));
        arcade.remainingPackBackings(3);
    }

    // ------------------------------------------------------------------ pricing

    function test_quoteMatchesFormula() public {
        uint256 id = _createEpoch(_backings4());
        (
            uint256 price,
            uint256 fee,
            uint256 sponsorProceeds,
            uint256 expectedPayout,
            uint32 remainingCount,
            uint256 remainingBacking,
            uint32 version,
            bool open
        ) = arcade.quote(id);

        // ceil(1000e18 * 10000 / (4 * 9500)) = ceil(263157894736842105263.157...)
        uint256 numerator = uint256(1000e18) * 10_000;
        uint256 denominator = 4 * 9_500;
        uint256 expectedPrice = (numerator + denominator - 1) / denominator;
        assertEq(price, expectedPrice);
        assertEq(price, 263157894736842105264);
        assertEq(fee, price * 500 / 10_000);
        assertEq(sponsorProceeds, price - fee);
        assertEq(expectedPayout, 250e18);
        assertEq(remainingCount, 4);
        assertEq(remainingBacking, 1000e18);
        assertEq(version, 0);
        assertTrue(open);
        // Expected payout is 95% of price (up to rounding of one unit).
        assertApproxEqAbs(expectedPayout * 10_000, price * 9_500, 10_000);
    }

    function testFuzz_priceIsCeilAndNeverBelowFairPlusEdge(uint256 backing, uint256 count) public view {
        backing = bound(backing, 1, 1e27);
        count = bound(count, 1, 64);
        uint256 price = arcade.priceFor(backing, count);
        // price * N * 9500 >= B * 10000 (ceil), and strictly less than that plus one denominator unit
        assertGe(price * count * 9_500, backing * 10_000);
        assertLt(price * count * 9_500, backing * 10_000 + count * 9_500);
    }

    // ------------------------------------------------------------------ draw request

    function test_drawPullsPriceSplitsProceedsAndRequestsRandomness() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        uint256 fee = price * 500 / 10_000;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit AgentArcade.DrawRequested(1, id, alice, 1000, price, fee, version);
        vm.prank(alice);
        uint256 drawId = arcade.draw(id, version, price);

        assertEq(drawId, 1);
        assertEq(arcade.pendingDrawId(), 1);
        assertEq(token.balanceOf(alice), aliceBefore - price);
        assertEq(arcade.withdrawable(feeRecipient), fee);
        assertEq(arcade.withdrawable(sponsor), price - fee);
        assertEq(arcade.totalWithdrawable(), price);
        _assertSolvent();

        AgentArcade.Draw memory d = arcade.drawInfo(drawId);
        assertEq(d.buyer, alice);
        assertEq(d.epochId, id);
        assertEq(d.requestedAt, block.timestamp);
        assertEq(uint8(d.status), uint8(AgentArcade.DrawStatus.Requested));
        assertEq(d.price, price);
        assertEq(d.fee, fee);
        assertEq(d.requestId, 1000);
        assertEq(arcade.drawByRequestId(1000), drawId);

        // The VRF request carries the configured parameters and the v2.5 extraArgs encoding.
        (address consumer, bytes32 keyHash, uint256 subId, uint16 confs, uint32 gas, uint32 numWords,) =
            vrf.requests(1000);
        assertEq(consumer, address(arcade));
        assertEq(keyHash, KEY_HASH);
        assertEq(subId, SUB_ID);
        assertEq(confs, CONFIRMATIONS);
        assertEq(gas, CALLBACK_GAS);
        assertEq(numWords, 1);
        assertEq(vrf.extraArgsOf(1000), VRFV2PlusExtraArgs.encode(true));
        assertEq(bytes4(vrf.extraArgsOf(1000)), bytes4(keccak256("VRF ExtraArgsV1")));
    }

    function test_drawAllowsMaxCostAboveQuote() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price + 1e18);
        assertEq(arcade.drawInfo(1).price, price, "buyer is charged the quote, not maxCost");
    }

    function test_drawRevertsWhenCostTooHigh() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.CostTooHigh.selector, price, price - 1));
        arcade.draw(id, version, price - 1);
    }

    function test_drawRevertsOnStaleInventoryVersion() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price,) = _price(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.StaleInventory.selector, 5, 0));
        arcade.draw(id, 5, price);
    }

    function test_drawRevertsWhileAnotherDrawIsPending() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.DrawPending.selector, 1));
        arcade.draw(id, version, price);

        // Still pending after fulfilment until settled.
        vrf.fulfill(1000, 42);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.DrawPending.selector, 1));
        arcade.draw(id, version, price);
    }

    function test_drawRevertsWhenPaused() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(sponsor);
        arcade.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(AgentArcade.IsPaused.selector);
        arcade.draw(id, version, price);
    }

    function test_drawRevertsOnUnknownEpoch() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.UnknownEpoch.selector, 9));
        arcade.draw(9, 0, 1e30);
    }

    function test_drawRevertsWithoutAllowanceOrBalance() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        address broke = makeAddr("broke");
        vm.prank(broke);
        vm.expectRevert();
        arcade.draw(id, version, price);
        assertEq(arcade.pendingDrawId(), 0);
        assertEq(arcade.drawCount(), 0);
    }

    // ------------------------------------------------------------------ randomness callback

    function test_fulfilOnlyByCoordinator() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);

        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(alice);
        vm.expectRevert(AgentArcade.NotCoordinator.selector);
        arcade.rawFulfillRandomWords(1000, words);
    }

    function test_fulfilStoresRandomnessOnly() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);

        vm.expectEmit(true, true, false, true);
        emit AgentArcade.RandomnessReceived(1, 1000, 12345);
        vrf.fulfill(1000, 12345);

        AgentArcade.Draw memory d = arcade.drawInfo(1);
        assertEq(uint8(d.status), uint8(AgentArcade.DrawStatus.Fulfilled));
        assertEq(d.randomness, 12345);
        // Inventory untouched until settlement.
        assertEq(arcade.epochInfo(id).remainingCount, 4);
        assertEq(arcade.epochInfo(id).version, 0);
        assertEq(arcade.pendingDrawId(), 1);
    }

    function test_duplicateOrUnknownFulfilmentIsIgnored() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);

        vrf.fulfill(1000, 12345);
        vrf.fulfill(1000, 99999); // duplicate: must not overwrite or revert
        assertEq(arcade.drawInfo(1).randomness, 12345);

        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(address(vrf));
        arcade.rawFulfillRandomWords(555, words); // unknown request: silently ignored

        uint256[] memory empty = new uint256[](0);
        vm.prank(address(vrf));
        arcade.rawFulfillRandomWords(1000, empty); // empty words: ignored
        assertEq(arcade.drawInfo(1).randomness, 12345);
    }

    function test_fulfilAfterSettlementDoesNotReopenDraw() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vrf.fulfill(1000, 3);
        arcade.settle(1);
        vrf.fulfill(1000, 4);
        assertEq(uint8(arcade.drawInfo(1).status), uint8(AgentArcade.DrawStatus.Settled));
        assertEq(arcade.drawInfo(1).randomness, 3);
    }

    // ------------------------------------------------------------------ settlement

    function test_settleBeforeFulfilmentReverts() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vm.expectRevert(
            abi.encodeWithSelector(AgentArcade.WrongDrawStatus.selector, 1, AgentArcade.DrawStatus.Requested)
        );
        arcade.settle(1);
    }

    function test_settleUnknownDrawReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.UnknownDraw.selector, 0));
        arcade.settle(0);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.UnknownDraw.selector, 1));
        arcade.settle(1);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.UnknownDraw.selector, 1));
        arcade.drawInfo(1);
    }

    function test_settlePicksIndexFromRandomnessAndUpdatesInventory() public {
        uint256 id = _createEpoch(_backings4()); // [100,100,300,500]
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vrf.fulfill(1000, 4 * 10 + 2); // 42 % 4 == 2 -> 300e18

        vm.expectEmit(true, true, false, true);
        emit AgentArcade.DrawSettled(1, id, 300e18, 1, true);
        vm.prank(keeper);
        arcade.settle(1);

        AgentArcade.Draw memory d = arcade.drawInfo(1);
        assertEq(uint8(d.status), uint8(AgentArcade.DrawStatus.Settled));
        assertEq(d.backing, 300e18);
        assertEq(arcade.pendingDrawId(), 0);
        assertEq(arcade.unsoldBacking(), 700e18);
        assertEq(arcade.reservedBacking(), 300e18);

        AgentArcade.Epoch memory e = arcade.epochInfo(id);
        assertEq(e.remainingCount, 3);
        assertEq(e.remainingBacking, 700e18);
        assertEq(e.version, 1);
        assertEq(e.distinctValues, 2);
        assertTrue(e.drawsOpen);

        // swap-and-pop: last element moved into slot 2
        uint256[] memory remaining = arcade.remainingPackBackings(id);
        assertEq(remaining.length, 3);
        assertEq(remaining[0], 100e18);
        assertEq(remaining[1], 100e18);
        assertEq(remaining[2], 500e18);
        _assertSolvent();
    }

    function test_settleTwiceReverts() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vrf.fulfill(1000, 1);
        arcade.settle(1);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.WrongDrawStatus.selector, 1, AgentArcade.DrawStatus.Settled));
        arcade.settle(1);
    }

    function test_settleClosesEpochWhenFewerThanTwoDistinctValuesRemain() public {
        uint256[] memory b = new uint256[](3);
        b[0] = 10e18;
        b[1] = 10e18;
        b[2] = 40e18;
        uint256 id = _createEpoch(b);

        // Randomness 2 -> index 2 -> the 40e18 pack. Only 10e18 packs remain: draws stop.
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vrf.fulfill(1000, 2);
        vm.expectEmit(true, true, false, true);
        emit AgentArcade.DrawSettled(1, id, 40e18, 1, false);
        arcade.settle(1);

        AgentArcade.Epoch memory e = arcade.epochInfo(id);
        assertFalse(e.drawsOpen);
        assertEq(e.distinctValues, 1);
        assertEq(e.remainingCount, 2);

        (,,,,,,, bool open) = arcade.quote(id);
        assertFalse(open);
        (uint256 p2, uint32 v2) = _price(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.DrawsClosed.selector, id));
        arcade.draw(id, v2, p2);
    }

    function test_settleKeepsEpochOpenWhileTwoValuesRemain() public {
        uint256[] memory b = new uint256[](3);
        b[0] = 10e18;
        b[1] = 10e18;
        b[2] = 40e18;
        uint256 id = _createEpoch(b);
        _play(alice, id, 0); // index 0 -> 10e18, remaining [40,10]
        assertTrue(arcade.epochInfo(id).drawsOpen);
        assertEq(arcade.epochInfo(id).distinctValues, 2);
    }

    // ------------------------------------------------------------------ delivery

    function test_deliverMintsPackToBuyer() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vrf.fulfill(1000, 3); // index 3 -> 500e18
        arcade.settle(1);

        vm.expectEmit(true, true, true, true);
        emit AgentArcade.Transfer(address(0), alice, 1);
        vm.expectEmit(true, true, true, true);
        emit AgentArcade.PrizeDelivered(1, 1, alice);
        vm.prank(keeper);
        arcade.deliver(1);

        assertEq(arcade.ownerOf(1), alice);
        assertEq(arcade.balanceOf(alice), 1);
        assertEq(arcade.packBacking(1), 500e18);
        assertEq(arcade.packEpoch(1), id);
        assertEq(arcade.reservedBacking(), 0);
        assertEq(arcade.mintedBacking(), 500e18);
        assertEq(uint8(arcade.drawInfo(1).status), uint8(AgentArcade.DrawStatus.Delivered));
        assertEq(arcade.drawInfo(1).packId, 1);
        _assertSolvent();
    }

    function test_deliverBeforeSettleOrTwiceReverts() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vm.expectRevert(
            abi.encodeWithSelector(AgentArcade.WrongDrawStatus.selector, 1, AgentArcade.DrawStatus.Requested)
        );
        arcade.deliver(1);
        vrf.fulfill(1000, 3);
        vm.expectRevert(
            abi.encodeWithSelector(AgentArcade.WrongDrawStatus.selector, 1, AgentArcade.DrawStatus.Fulfilled)
        );
        arcade.deliver(1);
        arcade.settle(1);
        arcade.deliver(1);
        vm.expectRevert(
            abi.encodeWithSelector(AgentArcade.WrongDrawStatus.selector, 1, AgentArcade.DrawStatus.Delivered)
        );
        arcade.deliver(1);
    }

    function test_deliveryCannotBeBlockedByRecipient() public {
        Rejecter rejecter = new Rejecter();
        vm.prank(alice);
        token.transfer(address(rejecter), 10_000e18);
        vm.prank(address(rejecter));
        token.approve(address(arcade), type(uint256).max);

        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(address(rejecter));
        arcade.draw(id, version, price);
        vrf.fulfill(1000, 0);
        arcade.settle(1);
        // A third party delivers; the recipient's receive hook is never consulted for delivery.
        vm.prank(keeper);
        arcade.deliver(1);
        assertEq(arcade.ownerOf(1), address(rejecter));
    }

    function test_nextDrawCanStartAfterSettleBeforeDelivery() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vrf.fulfill(1000, 0);
        arcade.settle(1);

        (uint256 price2, uint32 version2) = _price(id);
        assertEq(version2, 1);
        vm.prank(bob);
        uint256 drawId2 = arcade.draw(id, version2, price2);
        assertEq(drawId2, 2);
        assertEq(arcade.pendingDrawId(), 2);
        arcade.deliver(1);
        assertEq(arcade.ownerOf(1), alice);
    }

    // ------------------------------------------------------------------ redemption

    function test_redeemBurnsPackAndPaysOwner() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3); // 500e18
        uint256 aliceBefore = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit AgentArcade.Transfer(alice, address(0), packId);
        vm.expectEmit(true, true, false, true);
        emit AgentArcade.PackRedeemed(packId, alice, 500e18);
        vm.prank(alice);
        arcade.redeem(packId);

        assertEq(token.balanceOf(alice), aliceBefore + 500e18);
        assertEq(arcade.mintedBacking(), 0);
        assertEq(arcade.balanceOf(alice), 0);
        assertEq(arcade.packBacking(packId), 0);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, packId));
        arcade.ownerOf(packId);
        _assertSolvent();
    }

    function test_redeemTwiceReverts() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3);
        vm.prank(alice);
        arcade.redeem(packId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, packId));
        arcade.redeem(packId);
    }

    function test_redeemByNonOwnerOrApprovedReverts() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3);
        vm.prank(alice);
        arcade.approve(bob, packId);
        vm.prank(bob);
        vm.expectRevert(AgentArcade.NotOwner.selector);
        arcade.redeem(packId);
        assertEq(arcade.ownerOf(packId), alice);
    }

    function test_redeemPaysCurrentOwnerAfterTransfer() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3);
        vm.prank(alice);
        arcade.transferFrom(alice, bob, packId);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        arcade.redeem(packId);
        assertEq(token.balanceOf(bob), bobBefore + 500e18);
    }

    function test_redeemInsideReceiveHookCannotDoubleRedeem() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3);
        DoubleRedeemer attacker = new DoubleRedeemer(arcade);
        vm.prank(alice);
        arcade.safeTransferFrom(alice, address(attacker), packId);
        assertTrue(attacker.secondRedeemFailed());
        assertEq(token.balanceOf(address(attacker)), 500e18);
        assertEq(arcade.mintedBacking(), 0);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ payments

    function test_withdrawPaymentsPaysExactShares() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 price,) = _price(id);
        uint256 fee = price * 500 / 10_000;
        _play(alice, id, 0);

        vm.expectEmit(true, false, false, true);
        emit AgentArcade.PaymentsWithdrawn(sponsor, price - fee);
        vm.prank(sponsor);
        uint256 got = arcade.withdrawPayments();
        assertEq(got, price - fee);
        assertEq(token.balanceOf(sponsor), 100_000e18 - 1000e18 + price - fee);

        vm.prank(feeRecipient);
        assertEq(arcade.withdrawPayments(), fee);
        assertEq(token.balanceOf(feeRecipient), fee);
        assertEq(arcade.totalWithdrawable(), 0);
        _assertSolvent();
    }

    function test_withdrawNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentArcade.NothingToWithdraw.selector);
        arcade.withdrawPayments();
        vm.prank(sponsor);
        vm.expectRevert(AgentArcade.NothingToWithdraw.selector);
        arcade.withdrawPayments();
    }

    function test_paymentsAccumulateAcrossDraws() public {
        uint256 id = _createEpoch(_backings4());
        (uint256 p1,) = _price(id);
        _play(alice, id, 0);
        (uint256 p2,) = _price(id);
        _play(bob, id, 0);
        uint256 f1 = p1 * 500 / 10_000;
        uint256 f2 = p2 * 500 / 10_000;
        assertEq(arcade.withdrawable(feeRecipient), f1 + f2);
        assertEq(arcade.withdrawable(sponsor), p1 + p2 - f1 - f2);
    }

    // ------------------------------------------------------------------ pause

    function test_pauseOnlySponsorAndOnlyStopsDraws() public {
        uint256 id = _createEpoch(_backings4());
        // Bob wins a pack first, then alice starts a draw that stays pending while we pause.
        (, uint256 bobPack) = _play(bob, id, 0);
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        uint256 pendingId = arcade.draw(id, version, price);

        vm.prank(alice);
        vm.expectRevert(AgentArcade.NotSponsor.selector);
        arcade.setPaused(true);

        vm.expectEmit(false, false, false, true);
        emit AgentArcade.PauseSet(true);
        vm.prank(sponsor);
        arcade.setPaused(true);
        assertTrue(arcade.paused());

        // Pending draw settles, delivers, redeems and pays out while paused.
        vrf.fulfill(arcade.drawInfo(pendingId).requestId, 1);
        arcade.settle(pendingId);
        arcade.deliver(pendingId);
        uint256 alicePack = arcade.drawInfo(pendingId).packId;
        vm.prank(alice);
        arcade.redeem(alicePack);
        vm.prank(bob);
        arcade.redeem(bobPack);
        vm.prank(sponsor);
        arcade.withdrawPayments();
        _assertSolvent();

        // Sponsor may still create epochs, but nobody can draw.
        vm.prank(sponsor);
        uint256 id2 = arcade.createEpoch(_backings4());
        (uint256 p2, uint32 v2) = _price(id2);
        vm.prank(bob);
        vm.expectRevert(AgentArcade.IsPaused.selector);
        arcade.draw(id2, v2, p2);

        vm.prank(sponsor);
        arcade.setPaused(false);
        assertFalse(arcade.paused());
        vm.prank(bob);
        arcade.draw(id2, v2, p2);
    }

    // ------------------------------------------------------------------ sweep

    function test_sweepRequiresClosedEpochAndNoPendingDraw() public {
        uint256[] memory b = new uint256[](3);
        b[0] = 10e18;
        b[1] = 10e18;
        b[2] = 40e18;
        uint256 id = _createEpoch(b);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.EpochStillOpen.selector, id));
        arcade.sweepEpoch(id);

        // Close it by drawing the 40e18 pack, but leave the draw un-settled first.
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vrf.fulfill(1000, 2);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.EpochStillOpen.selector, id));
        arcade.sweepEpoch(id);
        arcade.settle(1);
        assertFalse(arcade.epochInfo(id).drawsOpen);

        vm.prank(alice);
        vm.expectRevert(AgentArcade.NotSponsor.selector);
        arcade.sweepEpoch(id);

        uint256 sponsorBefore = arcade.balanceOf(sponsor);
        vm.expectEmit(true, false, false, true);
        emit AgentArcade.EpochSwept(id, 2, 20e18);
        vm.prank(sponsor);
        arcade.sweepEpoch(id);

        assertEq(arcade.balanceOf(sponsor), sponsorBefore + 2);
        assertEq(arcade.unsoldBacking(), 0);
        assertEq(arcade.mintedBacking(), 20e18);
        assertEq(arcade.reservedBacking(), 40e18);
        AgentArcade.Epoch memory e = arcade.epochInfo(id);
        assertTrue(e.swept);
        assertEq(e.remainingCount, 0);
        assertEq(e.remainingBacking, 0);
        assertEq(arcade.remainingPackBackings(id).length, 0);
        _assertSolvent();

        // Swept packs are ordinary packs: the sponsor redeems them.
        uint256 sponsorTokens = token.balanceOf(sponsor);
        assertEq(arcade.ownerOf(1), sponsor);
        assertEq(arcade.ownerOf(2), sponsor);
        vm.prank(sponsor);
        arcade.redeem(1);
        vm.prank(sponsor);
        arcade.redeem(2);
        assertEq(token.balanceOf(sponsor), sponsorTokens + 20e18);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.AlreadySwept.selector, id));
        arcade.sweepEpoch(id);
        _assertSolvent();
    }

    function test_sweepBlockedWhilePendingDrawOnSameEpochButNotOther() public {
        // Epoch 1: closes after one draw.
        uint256[] memory b = new uint256[](2);
        b[0] = 1e18;
        b[1] = 2e18;
        uint256 id1 = _createEpoch(b);
        uint256 id2 = _createEpoch(_backings4());

        // Draw on epoch 1 closes it (2 packs, either pick leaves one value).
        _play(alice, id1, 1);
        assertFalse(arcade.epochInfo(id1).drawsOpen);

        // Pending draw on epoch 2 does not block sweeping epoch 1.
        (uint256 price, uint32 version) = _price(id2);
        vm.prank(bob);
        arcade.draw(id2, version, price);
        vm.prank(sponsor);
        arcade.sweepEpoch(id1);
        assertTrue(arcade.epochInfo(id1).swept);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ full play-through

    function test_playThroughConservesEveryToken() public {
        uint256[] memory b = new uint256[](6);
        b[0] = 10e18;
        b[1] = 20e18;
        b[2] = 30e18;
        b[3] = 40e18;
        b[4] = 50e18;
        b[5] = 60e18;
        uint256 id = _createEpoch(b);
        uint256 totalBacking = 210e18;

        uint256 paid;
        uint256 randomness = uint256(keccak256("seed"));
        uint256 draws;
        while (arcade.epochInfo(id).drawsOpen) {
            (uint256 price,) = _price(id);
            paid += price;
            _play(draws % 2 == 0 ? alice : bob, id, randomness);
            randomness = uint256(keccak256(abi.encode(randomness)));
            ++draws;
            _assertSolvent();
        }
        // Six distinct values: draws stop only when a single pack remains.
        assertEq(draws, 5);
        assertEq(arcade.epochInfo(id).remainingCount, 1);

        vm.prank(sponsor);
        arcade.sweepEpoch(id);
        assertEq(arcade.unsoldBacking(), 0);
        assertEq(arcade.mintedBacking(), totalBacking);
        assertEq(arcade.totalWithdrawable(), paid);

        // Everyone redeems, sponsor & fee recipient withdraw: contract ends empty.
        for (uint256 p = 1; p <= 6; ++p) {
            address owner = arcade.ownerOf(p);
            vm.prank(owner);
            arcade.redeem(p);
        }
        vm.prank(sponsor);
        arcade.withdrawPayments();
        vm.prank(feeRecipient);
        arcade.withdrawPayments();
        assertEq(token.balanceOf(address(arcade)), 0);
        assertEq(arcade.totalLiabilities(), 0);

        uint256 totalFees = token.balanceOf(feeRecipient);
        // Fee is floor(5%) per draw, so total fee is within one wei per draw of 5% overall.
        assertApproxEqAbs(totalFees, paid * 500 / 10_000, draws);
        assertEq(
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(sponsor) + totalFees,
            300_000e18,
            "tokens leaked"
        );
    }

    function testFuzz_settlementUsesEveryIndexWithEqualOdds(uint256 randomness) public {
        uint256 id = _createEpoch(_backings4());
        uint256[] memory before = arcade.remainingPackBackings(id);
        (uint256 price, uint32 version) = _price(id);
        vm.prank(alice);
        arcade.draw(id, version, price);
        vrf.fulfill(1000, randomness);
        arcade.settle(1);
        assertEq(arcade.drawInfo(1).backing, before[randomness % 4]);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ ERC-721 surface

    function test_erc721TransferApproveAndSafeTransfer() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3);

        assertTrue(arcade.supportsInterface(0x80ac58cd));
        assertTrue(arcade.supportsInterface(0x5b5e139f));
        assertTrue(arcade.supportsInterface(0x01ffc9a7));
        assertFalse(arcade.supportsInterface(0xffffffff));
        assertEq(arcade.name(), "Agent Arcade Pack");
        assertEq(arcade.symbol(), "PACK");
        assertEq(arcade.getApproved(packId), address(0), "new pack has no approval");

        // Unauthorized transfer fails.
        vm.prank(bob);
        vm.expectRevert(AgentArcade.NotAuthorized.selector);
        arcade.transferFrom(alice, bob, packId);

        // Wrong `from` fails.
        vm.prank(alice);
        vm.expectRevert(AgentArcade.WrongFrom.selector);
        arcade.transferFrom(bob, alice, packId);

        // To zero fails.
        vm.prank(alice);
        vm.expectRevert(AgentArcade.ZeroAddress.selector);
        arcade.transferFrom(alice, address(0), packId);

        // Approval path.
        vm.prank(alice);
        arcade.approve(bob, packId);
        assertEq(arcade.getApproved(packId), bob);
        vm.prank(bob);
        arcade.transferFrom(alice, bob, packId);
        assertEq(arcade.ownerOf(packId), bob);
        assertEq(arcade.getApproved(packId), address(0), "approval cleared on transfer");
        assertEq(arcade.balanceOf(alice), 0);
        assertEq(arcade.balanceOf(bob), 1);

        // Operator path.
        vm.prank(bob);
        arcade.setApprovalForAll(alice, true);
        assertTrue(arcade.isApprovedForAll(bob, alice));
        Receiver receiver = new Receiver();
        vm.prank(alice);
        arcade.safeTransferFrom(bob, address(receiver), packId);
        assertEq(arcade.ownerOf(packId), address(receiver));

        // Safe transfer to a rejecting contract fails.
        Rejecter rejecter = new Rejecter();
        vm.prank(address(receiver));
        vm.expectRevert(AgentArcade.UnsafeRecipient.selector);
        arcade.safeTransferFrom(address(receiver), address(rejecter), packId);

        // Plain transferFrom to a rejecting contract is the sender's choice and succeeds.
        vm.prank(address(receiver));
        arcade.transferFrom(address(receiver), address(rejecter), packId);
        assertEq(arcade.ownerOf(packId), address(rejecter));
    }

    function test_erc721ViewsRevertForNonexistentOrZero() public {
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, 1));
        arcade.ownerOf(1);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, 1));
        arcade.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, 1));
        arcade.getApproved(1);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, 1));
        arcade.approve(bob, 1);
        vm.expectRevert(AgentArcade.ZeroAddress.selector);
        arcade.balanceOf(address(0));
    }

    function test_tokenURIEncodesEpochAndBacking() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3);
        string memory metadata = _decodeMetadata(arcade.tokenURI(packId));
        assertEq(
            metadata,
            '{"name":"Agent Arcade Pack #1","description":"Collectible pack fully backed by WFD. Redeem to receive the backing.","attributes":[{"trait_type":"epoch","value":1},{"trait_type":"backing","value":"500000000000000000000"}]}'
        );
        assertEq(vm.parseJsonString(metadata, ".name"), "Agent Arcade Pack #1");
        assertEq(vm.parseJsonUint(metadata, ".attributes[0].value"), id);
        assertEq(vm.parseJsonString(metadata, ".attributes[1].value"), "500000000000000000000");
    }

    function test_sweptPackMetadataDecodesAndRevertsAfterRedemption() public {
        _createEpoch(_backings4());
        uint256[] memory backings = new uint256[](2);
        backings[0] = 100e18;
        backings[1] = 500e18;
        uint256 id = _createEpoch(backings);
        _play(alice, id, 1);
        vm.prank(sponsor);
        arcade.sweepEpoch(id);

        string memory metadata = _decodeMetadata(arcade.tokenURI(2));
        assertEq(vm.parseJsonString(metadata, ".name"), "Agent Arcade Pack #2");
        assertEq(vm.parseJsonUint(metadata, ".attributes[0].value"), 2);
        assertEq(vm.parseJsonString(metadata, ".attributes[1].value"), "100000000000000000000");
        assertEq(arcade.getApproved(2), address(0));
        vm.prank(sponsor);
        arcade.redeem(2);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, 2));
        arcade.tokenURI(2);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, 2));
        arcade.getApproved(2);
    }

    function testFuzz_getApprovedRevertsForUnmintedPack(uint256 packId) public {
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, packId));
        arcade.getApproved(packId);
    }

    function test_getApprovedRevertsAfterApprovedPackIsRedeemed() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3);
        vm.prank(alice);
        arcade.approve(bob, packId);
        assertEq(arcade.getApproved(packId), bob);
        vm.prank(alice);
        arcade.redeem(packId);
        vm.expectRevert(abi.encodeWithSelector(AgentArcade.NonexistentPack.selector, packId));
        arcade.getApproved(packId);
    }

    /// @dev Decode the data URL before inspecting its JSON, rejecting raw URI delimiters.
    function _decodeMetadata(string memory uri) internal pure returns (string memory) {
        bytes memory encoded = bytes(uri);
        bytes memory prefix = bytes("data:application/json;utf8,");
        assertGe(encoded.length, prefix.length);
        for (uint256 i; i < prefix.length; ++i) {
            assertEq(encoded[i], prefix[i]);
        }
        bytes memory decoded = new bytes(encoded.length - prefix.length);
        uint256 length;
        for (uint256 i = prefix.length; i < encoded.length; ++i) {
            assertTrue(encoded[i] != "#" && encoded[i] != "?", "raw URI delimiter in JSON payload");
            if (encoded[i] == "%") {
                assertLt(i + 2, encoded.length, "incomplete percent escape");
                bytes memory octet = vm.parseBytes(string(abi.encodePacked("0x", encoded[i + 1], encoded[i + 2])));
                decoded[length++] = octet[0];
                i += 2;
            } else {
                decoded[length++] = encoded[i];
            }
        }
        assembly ("memory-safe") {
            mstore(decoded, length)
        }
        return string(decoded);
    }

    function test_approveByOperatorAndNotByStranger() public {
        uint256 id = _createEpoch(_backings4());
        (, uint256 packId) = _play(alice, id, 3);
        vm.prank(bob);
        vm.expectRevert(AgentArcade.NotAuthorized.selector);
        arcade.approve(bob, packId);
        vm.prank(alice);
        arcade.setApprovalForAll(bob, true);
        vm.prank(bob);
        arcade.approve(keeper, packId);
        assertEq(arcade.getApproved(packId), keeper);
    }

    // ------------------------------------------------------------------ runtime

    function test_runtimeIsBoundedAndHasNoEscapeOpcodes() public view {
        bytes memory code = address(arcade).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden project opcode");
        }
    }

    function test_surplusIsLockedButAccountedSeparately() public {
        uint256 id = _createEpoch(_backings4());
        vm.prank(alice);
        token.transfer(address(arcade), 7e18); // mistaken send
        assertEq(arcade.surplus(), 7e18);
        assertEq(arcade.totalLiabilities(), 1000e18);
        _play(alice, id, 0);
        assertEq(arcade.surplus(), 7e18, "surplus is not consumed by play");
    }
}
