// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title AutoVaultStorage
/// @notice Diamond storage for AutoVault state
library AutoVaultStorage {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 internal constant SLOT = keccak256("autovault.storage.v1");

    struct Layout {
        // ═══════════════════════════════════════════════════════════════════
        // RAMSES CONTRACTS
        // ═══════════════════════════════════════════════════════════════════
        address xRam;
        address voteModule;
        address voter;
        address accessHub;
        // ═══════════════════════════════════════════════════════════════════
        // OPERATOR & CONFIGURATION
        // ═══════════════════════════════════════════════════════════════════
        address operator;
        EnumerableSet.AddressSet outputTokens;
        EnumerableSet.AddressSet aggregators;
        mapping(uint256 period => bool unlocked) periodUnlockStatus;
        // ═══════════════════════════════════════════════════════════════════
        // USER BALANCES
        // ═══════════════════════════════════════════════════════════════════
        uint256 totalSupply;
        mapping(address user => uint256 balance) balanceOf;
        mapping(address user => address output) outputPreference;
        mapping(address output => uint256 total) totalSupplyPerOutput;
        // ═══════════════════════════════════════════════════════════════════
        // REWARD DISTRIBUTION
        // ═══════════════════════════════════════════════════════════════════
        mapping(address output => uint256 accumulated) rewardPerTokenStored;
        mapping(address user => uint256 paid) userRewardPerTokenPaid;
        mapping(address user => uint256 stored) storedRewards;
        // ═══════════════════════════════════════════════════════════════════
        // INPUT BUDGET TRACKING
        // ═══════════════════════════════════════════════════════════════════
        // inputBudget[inputToken][outputToken] = how much of input can go to output
        mapping(address input => mapping(address output => uint256 remaining)) inputBudget;
        // track all input tokens with non-zero budgets (for operator enumeration)
        EnumerableSet.AddressSet claimedInputTokens;
        // for unwrapping legacy bribes
        address legacyRouter;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}
