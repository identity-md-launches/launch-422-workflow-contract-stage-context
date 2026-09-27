// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVRFCoordinatorV2Plus} from "../../src/interfaces/IVRFCoordinatorV2Plus.sol";

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @notice Local stand-in for Chainlink VRF v2.5. Records requests and lets a test fulfil them at will.
/// @dev This demonstrates the consumer's control flow only; it is not a source of randomness.
contract MockVRFCoordinator is IVRFCoordinatorV2Plus {
    uint256 public nextRequestId = 1000;
    uint256 public requestCount;

    struct Recorded {
        address consumer;
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    mapping(uint256 requestId => Recorded) public requests;

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        requestCount++;
        requests[requestId] = Recorded({
            consumer: msg.sender,
            keyHash: req.keyHash,
            subId: req.subId,
            requestConfirmations: req.requestConfirmations,
            callbackGasLimit: req.callbackGasLimit,
            numWords: req.numWords,
            extraArgs: req.extraArgs
        });
    }

    /// @notice Deliver one random word to the consumer that made `requestId`.
    function fulfill(uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IVRFConsumer(requests[requestId].consumer).rawFulfillRandomWords(requestId, words);
    }

    /// @notice Deliver an arbitrary word array (used to exercise the empty-array path).
    function fulfillWords(uint256 requestId, uint256[] calldata words) external {
        IVRFConsumer(requests[requestId].consumer).rawFulfillRandomWords(requestId, words);
    }

    function extraArgsOf(uint256 requestId) external view returns (bytes memory) {
        return requests[requestId].extraArgs;
    }
}
