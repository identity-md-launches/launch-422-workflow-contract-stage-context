// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVRFCoordinatorV2Plus, VRFV2PlusExtraArgs} from "./interfaces/IVRFCoordinatorV2Plus.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @title AgentArcade — FWA-inspired mystery packs backed by WFD
/// @notice One sponsor funds finite, immutable epochs of at most 64 collectible packs. Every pack is fully
/// backed by WFD held in this contract. A draw buys one uniformly random remaining pack of the chosen
/// epoch, priced at `ceil(B * 10000 / (N * 9500))` where `B` is the epoch's remaining backing and `N` its
/// remaining pack count. 5% of the price is a fee, the remainder is owed to the sponsor. The winner
/// receives the pack as an ERC-721 and may keep it, transfer it, or redeem its backing.
///
/// Randomness comes from Chainlink VRF v2.5. The callback only stores the random word; settlement and
/// prize delivery are separate, permissionless steps so no recipient can block the arcade. There is one
/// pending draw at a time and no cancellation or reroll once a draw is accepted.
///
/// Custody: this contract holds only pack backing and unpaid draw proceeds. Liquidity and Merkle claims
/// live in separate protocol contracts and are never touched here.
contract AgentArcade {
    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    uint256 public constant BPS = 10_000;
    /// @notice Fee taken from every draw price, in basis points.
    uint256 public constant FEE_BPS = 500;
    /// @notice Pricing keeps 95% of the price as expected payout: `price = ceil(B * BPS / (N * PAYOUT_BPS))`.
    uint256 public constant PAYOUT_BPS = 9_500;
    uint256 public constant MAX_PACKS_PER_EPOCH = 64;

    string public constant name = "Agent Arcade Pack";
    string public constant symbol = "PACK";

    // ---------------------------------------------------------------------------------------------
    // Immutable configuration (set once by the factory; no initializer exists)
    // ---------------------------------------------------------------------------------------------

    IERC20Minimal public immutable token;
    /// @notice The single sponsor. Funds epochs, receives 95% of draw prices, may pause new draws.
    address public immutable sponsor;
    /// @notice Receives the 5% fee on every draw.
    address public immutable feeRecipient;
    IVRFCoordinatorV2Plus public immutable vrfCoordinator;
    uint256 public immutable vrfSubscriptionId;
    bytes32 public immutable vrfKeyHash;
    uint32 public immutable vrfCallbackGasLimit;
    uint16 public immutable vrfRequestConfirmations;
    bool public immutable vrfNativePayment;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    enum DrawStatus {
        None,
        Requested,
        Fulfilled,
        Settled,
        Delivered
    }

    struct Epoch {
        uint64 createdAt;
        uint32 version; // inventory version; incremented on every settled draw
        uint32 packCount; // packs at creation
        uint32 remainingCount;
        uint32 distinctValues; // distinct backing values among remaining packs
        bool drawsOpen; // false once fewer than two distinct backing values remain
        bool swept;
        uint256 totalBacking; // at creation
        uint256 remainingBacking;
    }

    struct Draw {
        address buyer;
        uint64 epochId;
        uint64 requestedAt;
        DrawStatus status;
        uint32 versionAtRequest;
        uint256 requestId;
        uint256 price;
        uint256 fee;
        uint256 randomness;
        uint256 backing; // backing of the pack won, set at settlement
        uint256 packId; // set at delivery
    }

    // ---------------------------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------------------------

    bool public paused;
    uint256 private _reentrancyLock = 1;

    uint256 public epochCount;
    mapping(uint256 epochId => Epoch) private _epochs;
    mapping(uint256 epochId => uint256[]) private _remaining; // backing of each unsold pack
    mapping(uint256 epochId => mapping(uint256 backing => uint32)) private _valueCount;

    uint256 public drawCount;
    /// @notice The draw awaiting randomness or settlement; zero when none.
    uint256 public pendingDrawId;
    mapping(uint256 drawId => Draw) private _draws;
    mapping(uint256 requestId => uint256 drawId) public drawByRequestId;

    /// @notice Draw proceeds owed to the sponsor and fee recipient, withdrawable at any time.
    mapping(address account => uint256) public withdrawable;
    uint256 public totalWithdrawable;

    /// @notice Backing of packs not yet drawn, across all epochs.
    uint256 public unsoldBacking;
    /// @notice Backing of settled draws whose pack has not been delivered yet.
    uint256 public reservedBacking;
    /// @notice Backing of minted, unredeemed packs.
    uint256 public mintedBacking;

    // ERC-721
    uint256 public nextPackId;
    mapping(uint256 packId => address) private _ownerOf;
    mapping(address owner => uint256) private _balanceOf;
    mapping(uint256 packId => address) public getApproved;
    mapping(address owner => mapping(address operator => bool)) public isApprovedForAll;
    mapping(uint256 packId => uint256) public packEpoch;
    mapping(uint256 packId => uint256) public packBacking;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event EpochCreated(uint256 indexed epochId, uint256[] backings, uint256 totalBacking);
    event DrawRequested(
        uint256 indexed drawId,
        uint256 indexed epochId,
        address indexed buyer,
        uint256 requestId,
        uint256 price,
        uint256 fee,
        uint32 version
    );
    event RandomnessReceived(uint256 indexed drawId, uint256 indexed requestId, uint256 randomness);
    event DrawSettled(uint256 indexed drawId, uint256 indexed epochId, uint256 backing, uint32 newVersion, bool open);
    event PrizeDelivered(uint256 indexed drawId, uint256 indexed packId, address indexed to);
    event PackRedeemed(uint256 indexed packId, address indexed owner, uint256 backing);
    event EpochSwept(uint256 indexed epochId, uint256 packs, uint256 backing);
    event PaymentsWithdrawn(address indexed account, uint256 amount);
    event PauseSet(bool paused);

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidConfig();
    error NotSponsor();
    error NotCoordinator();
    error Reentrancy();
    error IsPaused();
    error InvalidPackCount(uint256 count);
    error ZeroBacking();
    error InsufficientVariety();
    error UnknownEpoch(uint256 epochId);
    error DrawsClosed(uint256 epochId);
    error DrawPending(uint256 drawId);
    error StaleInventory(uint32 expected, uint32 actual);
    error CostTooHigh(uint256 price, uint256 maxCost);
    error UnknownDraw(uint256 drawId);
    error WrongDrawStatus(uint256 drawId, DrawStatus status);
    error EpochStillOpen(uint256 epochId);
    error AlreadySwept(uint256 epochId);
    error NothingToWithdraw();
    error TransferFailed();
    error NotOwner();
    error NotAuthorized();
    error NonexistentPack(uint256 packId);
    error WrongFrom();
    error UnsafeRecipient();

    // ---------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------

    modifier onlySponsor() {
        if (msg.sender != sponsor) revert NotSponsor();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert Reentrancy();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param token_ The WFD launch token (manifest: `$token`).
    /// @param sponsor_ The single sponsor and administrator (manifest: `$owner`).
    /// @param feeRecipient_ Receives the 5% draw fee (manifest: `$owner` unless a separate treasury exists).
    /// @param coordinator_ Chainlink VRF v2.5 coordinator on the target chain.
    /// @param subscriptionId_ VRF subscription that must list this contract as a consumer.
    /// @param keyHash_ VRF gas lane.
    /// @param callbackGasLimit_ Gas for `rawFulfillRandomWords`; it only stores a word, 100k is ample.
    /// @param requestConfirmations_ Block confirmations before fulfilment (Sepolia minimum is 3).
    /// @param nativePayment_ Pay VRF in native ETH (true) or LINK (false).
    constructor(
        address token_,
        address sponsor_,
        address feeRecipient_,
        address coordinator_,
        uint256 subscriptionId_,
        bytes32 keyHash_,
        uint32 callbackGasLimit_,
        uint16 requestConfirmations_,
        bool nativePayment_
    ) {
        if (token_ == address(0) || sponsor_ == address(0) || feeRecipient_ == address(0) || coordinator_ == address(0))
        {
            revert ZeroAddress();
        }
        if (keyHash_ == bytes32(0) || callbackGasLimit_ == 0 || requestConfirmations_ == 0 || subscriptionId_ == 0) {
            revert InvalidConfig();
        }
        token = IERC20Minimal(token_);
        sponsor = sponsor_;
        feeRecipient = feeRecipient_;
        vrfCoordinator = IVRFCoordinatorV2Plus(coordinator_);
        vrfSubscriptionId = subscriptionId_;
        vrfKeyHash = keyHash_;
        vrfCallbackGasLimit = callbackGasLimit_;
        vrfRequestConfirmations = requestConfirmations_;
        vrfNativePayment = nativePayment_;
    }

    // ---------------------------------------------------------------------------------------------
    // Sponsor actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Fund a new immutable epoch. Pulls the sum of `backings` in WFD from the sponsor.
    /// @dev At least two distinct backing values are required, otherwise no draw could ever open.
    function createEpoch(uint256[] calldata backings) external nonReentrant onlySponsor returns (uint256 epochId) {
        uint256 count = backings.length;
        if (count < 2 || count > MAX_PACKS_PER_EPOCH) revert InvalidPackCount(count);

        epochId = ++epochCount;
        uint256 total = 0;
        uint32 distinct = 0;
        uint256[] storage remaining = _remaining[epochId];
        mapping(uint256 => uint32) storage valueCount = _valueCount[epochId];
        for (uint256 i; i < count; ++i) {
            uint256 backing = backings[i];
            if (backing == 0) revert ZeroBacking();
            total += backing;
            remaining.push(backing);
            if (valueCount[backing]++ == 0) ++distinct;
        }
        if (distinct < 2) revert InsufficientVariety();

        _epochs[epochId] = Epoch({
            createdAt: uint64(block.timestamp),
            version: 0,
            packCount: uint32(count),
            remainingCount: uint32(count),
            distinctValues: distinct,
            drawsOpen: true,
            swept: false,
            totalBacking: total,
            remainingBacking: total
        });
        unsoldBacking += total;
        emit EpochCreated(epochId, backings, total);

        _pull(msg.sender, total);
    }

    /// @notice Deliver the remaining packs of a closed epoch to the sponsor as NFTs.
    /// @dev Only after draws have stopped and no draw on this epoch is pending. Backing stays attached to
    /// the packs; the sponsor redeems them like any other holder.
    function sweepEpoch(uint256 epochId) external nonReentrant onlySponsor {
        Epoch storage epoch = _epoch(epochId);
        if (epoch.drawsOpen) revert EpochStillOpen(epochId);
        if (epoch.swept) revert AlreadySwept(epochId);
        if (pendingDrawId != 0 && _draws[pendingDrawId].epochId == epochId) revert DrawPending(pendingDrawId);

        uint256[] storage remaining = _remaining[epochId];
        uint256 count = remaining.length;
        uint256 backing = epoch.remainingBacking;
        epoch.swept = true;
        epoch.remainingCount = 0;
        epoch.remainingBacking = 0;
        epoch.distinctValues = 0;
        unsoldBacking -= backing;
        mintedBacking += backing;
        for (uint256 i; i < count; ++i) {
            uint256 value = remaining[i];
            _valueCount[epochId][value] = 0;
            _mintPack(sponsor, epochId, value);
        }
        delete _remaining[epochId];
        emit EpochSwept(epochId, count, backing);
    }

    /// @notice Pause or resume new draw requests. Settlement, delivery, redemption and withdrawals are
    /// never paused.
    function setPaused(bool paused_) external onlySponsor {
        paused = paused_;
        emit PauseSet(paused_);
    }

    // ---------------------------------------------------------------------------------------------
    // Player actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Buy one random remaining pack of `epochId`.
    /// @param expectedVersion The inventory version the quote was computed for; reverts if inventory changed.
    /// @param maxCost The most the buyer agrees to pay; reverts if the current price exceeds it.
    /// @dev Pulls the price in WFD, credits fee and sponsor proceeds, and requests randomness. The draw is
    /// accepted once this returns; it cannot be cancelled or rerolled.
    function draw(uint256 epochId, uint32 expectedVersion, uint256 maxCost)
        external
        nonReentrant
        returns (uint256 drawId)
    {
        if (paused) revert IsPaused();
        if (pendingDrawId != 0) revert DrawPending(pendingDrawId);
        Epoch storage epoch = _epoch(epochId);
        if (!epoch.drawsOpen) revert DrawsClosed(epochId);
        if (epoch.version != expectedVersion) revert StaleInventory(expectedVersion, epoch.version);

        uint256 price = _price(epoch.remainingBacking, epoch.remainingCount);
        if (price > maxCost) revert CostTooHigh(price, maxCost);
        uint256 fee = price * FEE_BPS / BPS;

        drawId = ++drawCount;
        pendingDrawId = drawId;
        withdrawable[feeRecipient] += fee;
        withdrawable[sponsor] += price - fee;
        totalWithdrawable += price;

        _pull(msg.sender, price);

        uint256 requestId = vrfCoordinator.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusExtraArgs.encode(vrfNativePayment)
            })
        );
        drawByRequestId[requestId] = drawId;

        _draws[drawId] = Draw({
            buyer: msg.sender,
            epochId: uint64(epochId),
            requestedAt: uint64(block.timestamp),
            status: DrawStatus.Requested,
            versionAtRequest: epoch.version,
            requestId: requestId,
            price: price,
            fee: fee,
            randomness: 0,
            backing: 0,
            packId: 0
        });
        emit DrawRequested(drawId, epochId, msg.sender, requestId, price, fee, epoch.version);
    }

    /// @notice VRF v2.5 callback. Stores the random word and nothing else.
    /// @dev Only the coordinator may call. A repeated or unknown fulfilment is ignored rather than
    /// reverted, because a reverting callback would consume the request and lose the randomness.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert NotCoordinator();
        uint256 drawId = drawByRequestId[requestId];
        if (drawId == 0 || randomWords.length == 0) return;
        Draw storage d = _draws[drawId];
        if (d.status != DrawStatus.Requested) return;
        d.randomness = randomWords[0];
        d.status = DrawStatus.Fulfilled;
        emit RandomnessReceived(drawId, requestId, randomWords[0]);
    }

    /// @notice Apply stored randomness: pick the pack, update inventory, free the pending slot.
    /// @dev Permissionless. Equal odds per remaining pack: index = randomness mod remaining count.
    function settle(uint256 drawId) external nonReentrant {
        Draw storage d = _draw(drawId);
        if (d.status != DrawStatus.Fulfilled) revert WrongDrawStatus(drawId, d.status);
        uint256 epochId = d.epochId;
        Epoch storage epoch = _epochs[epochId];
        uint256[] storage remaining = _remaining[epochId];

        uint256 count = remaining.length;
        uint256 index = d.randomness % count;
        uint256 backing = remaining[index];
        remaining[index] = remaining[count - 1];
        remaining.pop();

        mapping(uint256 => uint32) storage valueCount = _valueCount[epochId];
        if (--valueCount[backing] == 0) --epoch.distinctValues;
        epoch.remainingCount = uint32(count - 1);
        epoch.remainingBacking -= backing;
        ++epoch.version;
        if (epoch.distinctValues < 2) epoch.drawsOpen = false;

        unsoldBacking -= backing;
        reservedBacking += backing;
        d.backing = backing;
        d.status = DrawStatus.Settled;
        pendingDrawId = 0;
        emit DrawSettled(drawId, epochId, backing, epoch.version, epoch.drawsOpen);
    }

    /// @notice Mint the won pack to the buyer. Permissionless and free of callbacks, so nobody can block it.
    function deliver(uint256 drawId) external nonReentrant {
        Draw storage d = _draw(drawId);
        if (d.status != DrawStatus.Settled) revert WrongDrawStatus(drawId, d.status);
        uint256 backing = d.backing;
        reservedBacking -= backing;
        mintedBacking += backing;
        d.status = DrawStatus.Delivered;
        uint256 packId = _mintPack(d.buyer, d.epochId, backing);
        d.packId = packId;
        emit PrizeDelivered(drawId, packId, d.buyer);
    }

    /// @notice Burn a pack and send its backing to its current owner.
    function redeem(uint256 packId) external nonReentrant {
        address owner = _ownerOf[packId];
        if (owner == address(0)) revert NonexistentPack(packId);
        if (msg.sender != owner) revert NotOwner();
        uint256 backing = packBacking[packId];

        _balanceOf[owner] -= 1;
        delete _ownerOf[packId];
        delete getApproved[packId];
        delete packBacking[packId];
        mintedBacking -= backing;
        emit Transfer(owner, address(0), packId);
        emit PackRedeemed(packId, owner, backing);

        if (!token.transfer(owner, backing)) revert TransferFailed();
    }

    /// @notice Withdraw accumulated draw proceeds (sponsor share or fees).
    function withdrawPayments() external nonReentrant returns (uint256 amount) {
        amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        totalWithdrawable -= amount;
        emit PaymentsWithdrawn(msg.sender, amount);
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
    }

    // ---------------------------------------------------------------------------------------------
    // Transparency views
    // ---------------------------------------------------------------------------------------------

    /// @notice Current price and odds for a draw on `epochId`.
    /// @return price WFD charged for one draw.
    /// @return fee Portion of `price` that goes to the fee recipient.
    /// @return sponsorProceeds Portion of `price` that goes to the sponsor.
    /// @return expectedPayout Mean backing of a remaining pack (remaining backing / remaining count).
    /// @return remainingCount Each remaining pack has probability 1 / remainingCount.
    /// @return remainingBacking Total WFD still backing unsold packs of the epoch.
    /// @return version Pass to `draw` as `expectedVersion`.
    /// @return open Whether draws are currently possible for this epoch (ignores pause).
    function quote(uint256 epochId)
        external
        view
        returns (
            uint256 price,
            uint256 fee,
            uint256 sponsorProceeds,
            uint256 expectedPayout,
            uint32 remainingCount,
            uint256 remainingBacking,
            uint32 version,
            bool open
        )
    {
        Epoch storage epoch = _epoch(epochId);
        remainingCount = epoch.remainingCount;
        remainingBacking = epoch.remainingBacking;
        version = epoch.version;
        open = epoch.drawsOpen;
        if (remainingCount != 0) {
            price = _price(remainingBacking, remainingCount);
            fee = price * FEE_BPS / BPS;
            sponsorProceeds = price - fee;
            expectedPayout = remainingBacking / remainingCount;
        }
    }

    function epochInfo(uint256 epochId) external view returns (Epoch memory) {
        return _epoch(epochId);
    }

    /// @notice Backing of every unsold pack in the epoch, in internal order. Exact odds for a value are
    /// (occurrences of that value) / (array length).
    function remainingPackBackings(uint256 epochId) external view returns (uint256[] memory) {
        _epoch(epochId);
        return _remaining[epochId];
    }

    function drawInfo(uint256 drawId) external view returns (Draw memory) {
        return _draw(drawId);
    }

    /// @notice WFD this contract must hold to honour every outstanding obligation.
    function totalLiabilities() public view returns (uint256) {
        return unsoldBacking + reservedBacking + mintedBacking + totalWithdrawable;
    }

    /// @notice WFD held beyond liabilities (donations or mistaken transfers). Nobody can withdraw it.
    function surplus() external view returns (uint256) {
        return token.balanceOf(address(this)) - totalLiabilities();
    }

    /// @notice Pure pricing helper: `ceil(remainingBacking * 10000 / (remainingCount * 9500))`.
    function priceFor(uint256 remainingBacking, uint256 remainingCount) external pure returns (uint256) {
        return _price(remainingBacking, remainingCount);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-721
    // ---------------------------------------------------------------------------------------------

    function ownerOf(uint256 packId) public view returns (address owner) {
        owner = _ownerOf[packId];
        if (owner == address(0)) revert NonexistentPack(packId);
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _balanceOf[owner];
    }

    function approve(address spender, uint256 packId) external {
        address owner = ownerOf(packId);
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert NotAuthorized();
        getApproved[packId] = spender;
        emit Approval(owner, spender, packId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 packId) public {
        address owner = ownerOf(packId);
        if (from != owner) revert WrongFrom();
        if (to == address(0)) revert ZeroAddress();
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender] && msg.sender != getApproved[packId]) {
            revert NotAuthorized();
        }
        _balanceOf[from] -= 1;
        _balanceOf[to] += 1;
        _ownerOf[packId] = to;
        delete getApproved[packId];
        emit Transfer(from, to, packId);
    }

    function safeTransferFrom(address from, address to, uint256 packId) external {
        safeTransferFrom(from, to, packId, "");
    }

    function safeTransferFrom(address from, address to, uint256 packId, bytes memory data) public {
        transferFrom(from, to, packId);
        if (
            to.code.length != 0
                && IERC721Receiver(to).onERC721Received(msg.sender, from, packId, data)
                    != IERC721Receiver.onERC721Received.selector
        ) revert UnsafeRecipient();
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 // ERC-165
                || interfaceId == 0x80ac58cd // ERC-721
                || interfaceId == 0x5b5e139f; // ERC-721 Metadata
    }

    function tokenURI(uint256 packId) external view returns (string memory) {
        ownerOf(packId);
        return string.concat(
            'data:application/json;utf8,{"name":"Agent Arcade Pack #',
            _toString(packId),
            '","description":"Collectible pack fully backed by WFD. Redeem to receive the backing.","attributes":[{"trait_type":"epoch","value":',
            _toString(packEpoch[packId]),
            '},{"trait_type":"backing","value":"',
            _toString(packBacking[packId]),
            '"}]}'
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _price(uint256 remainingBacking, uint256 remainingCount) private pure returns (uint256) {
        uint256 denominator = remainingCount * PAYOUT_BPS;
        return (remainingBacking * BPS + denominator - 1) / denominator;
    }

    function _pull(address from, uint256 amount) private {
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _mintPack(address to, uint256 epochId, uint256 backing) private returns (uint256 packId) {
        packId = ++nextPackId;
        _ownerOf[packId] = to;
        _balanceOf[to] += 1;
        packEpoch[packId] = epochId;
        packBacking[packId] = backing;
        emit Transfer(address(0), to, packId);
    }

    function _epoch(uint256 epochId) private view returns (Epoch storage epoch) {
        if (epochId == 0 || epochId > epochCount) revert UnknownEpoch(epochId);
        epoch = _epochs[epochId];
    }

    function _draw(uint256 drawId) private view returns (Draw storage d) {
        if (drawId == 0 || drawId > drawCount) revert UnknownDraw(drawId);
        d = _draws[drawId];
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits = 0;
        while (temp != 0) {
            ++digits;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            buffer[--digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}
