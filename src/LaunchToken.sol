// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LaunchToken — Workflow Demo (WFD)
/// @notice Fixed-supply ERC-20 for the Agent Arcade launch.
/// @dev The whole supply is minted once, to `msg.sender`, in the constructor. The deployer is the
/// ProjectFactory, which splits the supply according to the pinned launch policy (liquidity, the
/// protocol MerkleDistributor and contributor rewards). There is no owner, no mint, no burn, no pause,
/// no blocklist, no fee and no upgrade path: what is deployed is all the token will ever do.
///
/// Supply note: the approved brief names a 1,000,000 WFD supply. The launch policy that admits a token
/// requires exactly 1,000,000,000 tokens (10^27 minor units) minted to the factory, and the factory
/// rejects any other supply. The policy figure is implemented here; the discrepancy is recorded in the
/// README as a review finding rather than silently resolved.
contract LaunchToken {
    string public constant name = "Workflow Demo";
    string public constant symbol = "WFD";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 WFD in 18-decimal minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    uint256 public immutable totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientAllowance(uint256 requested, uint256 available);
    error ZeroAddress();

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(amount, allowed);
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(amount, fromBalance);
        balanceOf[from] = fromBalance - amount;
        // Cannot overflow: the sum of all balances is bounded by the fixed total supply.
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
