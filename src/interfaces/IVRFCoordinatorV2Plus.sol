// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Chainlink VRF v2.5 (`VRFCoordinatorV2_5`) that Agent Arcade calls.
/// @dev Declared locally instead of vendoring the Chainlink package so the project has no
/// additional dependency. The struct layout and the `extraArgs` tag match
/// `VRFV2PlusClient` in the Chainlink contracts package (1.3.x) exactly; any drift would make the coordinator
/// reject the request rather than misinterpret it.
interface IVRFCoordinatorV2Plus {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    function requestRandomWords(RandomWordsRequest calldata req) external returns (uint256 requestId);
}

/// @notice Encoding helper for the `extraArgs` field of a VRF v2.5 request.
library VRFV2PlusExtraArgs {
    struct ExtraArgsV1 {
        bool nativePayment;
    }

    bytes4 internal constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));

    function encode(bool nativePayment) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, ExtraArgsV1({nativePayment: nativePayment}));
    }
}
