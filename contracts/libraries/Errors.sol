// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Central Errors Library
/// @notice Contains all custom errors used across the protocol
/// @dev Centralized error definitions to prevent redundancy
library Errors {
    /*//////////////////////////////////////////////////////////////
                                VOTER ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when attempting to interact with an already active gauge
    /// @param gauge The address of the gauge
    error ACTIVE_GAUGE(address gauge);

    /// @notice Thrown when attempting to interact with an inactive gauge
    /// @param gauge The address of the gauge
    error GAUGE_INACTIVE(address gauge);

    /// @notice Thrown when attempting to whitelist an already whitelisted token
    /// @param token The address of the token
    error ALREADY_WHITELISTED(address token);

    /// @notice Thrown when caller is not authorized to perform an action
    /// @param caller The address of the unauthorized caller
    error NOT_AUTHORIZED(address caller);

    /// @notice Thrown when token is not whitelisted
    /// @param token The address of the non-whitelisted token
    error NOT_WHITELISTED(address token);

    /// @notice Thrown when both tokens in a pair are not whitelisted
    error BOTH_NOT_WHITELISTED();

    /// @notice Thrown when address is not a valid pool
    /// @param pool The invalid pool address
    error NOT_POOL(address pool);

    /// @notice Thrown when contract is not initialized
    error NOT_INIT();

    /// @notice Thrown when array lengths don't match
    error LENGTH_MISMATCH();

    /// @notice Thrown when pool doesn't have an associated gauge
    /// @param pool The address of the pool
    error NO_GAUGE(address pool);

    /// @notice Thrown when rewards are already distributed for a period
    /// @param gauge The gauge address
    /// @param period The distribution period
    error ALREADY_DISTRIBUTED(address gauge, uint256 period);

    /// @notice Thrown when attempting to vote with zero amount
    /// @param pool The pool address
    error ZERO_VOTE(address pool);

    /// @notice Thrown when ratio exceeds maximum allowed
    /// @param _xRatio The excessive ratio value
    error RATIO_TOO_HIGH(uint256 _xRatio);

    /// @notice Thrown when vote operation fails
    error VOTE_UNSUCCESSFUL();

    /// @notice Thrown when an item already exists in a set
    /// @param item The duplicate item
    error ALREADY_ADDED(address item);

    /// @notice Thrown when an item is missing from a set
    /// @param item The missing item
    error NOT_FOUND(address item);

    /*//////////////////////////////////////////////////////////////
                            GAUGE V3 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the pool already has a gauge
    /// @param pool The address of the pool
    error GAUGE_EXISTS(address pool);

    /// @notice Thrown when caller is not the voter
    /// @param caller The address of the invalid caller
    error NOT_VOTER(address caller);

    /// @notice Thrown when amount is not greater than zero
    /// @param amt The invalid amount
    error NOT_GT_ZERO(uint256 amt);

    /// @notice Thrown when attempting to claim future rewards
    error CANT_CLAIM_FUTURE();

    /// @notice Thrown when attempting to reward past periods
    error CANT_REWARD_PAST();

    /// @notice Throw when gauge can't determine if using secondsInRange from the pool is safe
    error NEED_TEAM_TO_UPDATE();

    /// @notice Thrown when owner is not an authorized NFP manager
    error NOT_AUTHORIZED_CLAIMER(address owner);

    /*//////////////////////////////////////////////////////////////
                            GAUGE ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when amount is zero
    error ZERO_AMOUNT();

    /// @notice Thrown when stake notification fails
    error CANT_NOTIFY_STAKE();

    /// @notice Thrown when reward amount is too high
    error REWARD_TOO_HIGH();

    /// @notice Thrown when amount exceeds remaining balance
    /// @param amount The requested amount
    /// @param remaining The remaining balance
    error NOT_GREATER_THAN_REMAINING(uint256 amount, uint256 remaining);

    /// @notice Thrown when token operation fails
    /// @param token The address of the problematic token
    error TOKEN_ERROR(address token);

    /// @notice Thrown when an address is not an NfpManager
    error NOT_NFP_MANAGER(address nfpManager);

    /*//////////////////////////////////////////////////////////////
                        FEE DISTRIBUTOR ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when period is not finalized
    /// @param period The unfinalized period
    error NOT_FINALIZED(uint256 period);

    /// @notice Thrown when the destination of a redirect is not a feeDistributor
    /// @param destination Destination of the redirect
    error NOT_FEE_DISTRIBUTOR(address destination);

    /// @notice Thrown when the destination of a redirect's pool/pair has completely different tokens
    error DIFFERENT_DESTINATION_TOKENS();

    /*//////////////////////////////////////////////////////////////
                            PAIR ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when ratio is unstable
    error UNSTABLE_RATIO();

    /// @notice Thrown when safe transfer fails
    error SAFE_TRANSFER_FAILED();

    /// @notice Thrown on arithmetic overflow
    error OVERFLOW();

    /// @notice Thrown when skim operation is disabled
    error SKIM_DISABLED();

    /// @notice Thrown when insufficient liquidity is minted
    error INSUFFICIENT_LIQUIDITY_MINTED();

    /// @notice Thrown when insufficient liquidity is burned
    error INSUFFICIENT_LIQUIDITY_BURNED();

    /// @notice Thrown when output amount is insufficient
    error INSUFFICIENT_OUTPUT_AMOUNT();

    /// @notice Thrown when input amount is insufficient
    error INSUFFICIENT_INPUT_AMOUNT();

    /// @notice Generic insufficient liquidity error
    error INSUFFICIENT_LIQUIDITY();

    /// @notice Invalid transfer error
    error INVALID_TRANSFER();

    /// @notice K value error in AMM
    error K();

    /*//////////////////////////////////////////////////////////////
                        PAIR FACTORY ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when fee is too high
    error FEE_TOO_HIGH();

    /// @notice Thrown when fee is zero
    error ZERO_FEE();

    /// @notice Thrown when token assortment is invalid
    error INVALID_ASSORTMENT();

    /// @notice Thrown when address is zero
    error ZERO_ADDRESS();

    /// @notice Thrown when pair already exists
    error PAIR_EXISTS();

    /// @notice Thrown when fee split is invalid
    error INVALID_FEE_SPLIT();

    /*//////////////////////////////////////////////////////////////
                    FEE RECIPIENT FACTORY ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when treasury fee is invalid
    error INVALID_TREASURY_FEE();

    /*//////////////////////////////////////////////////////////////
                            ROUTER ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when deadline has expired
    error EXPIRED();

    /// @notice Thrown when tokens are identical
    error IDENTICAL();

    /// @notice Thrown when amount is insufficient
    error INSUFFICIENT_AMOUNT();

    /// @notice Thrown when path is invalid
    error INVALID_PATH();

    /// @notice Thrown when token B amount is insufficient
    error INSUFFICIENT_B_AMOUNT();

    /// @notice Thrown when token A amount is insufficient
    error INSUFFICIENT_A_AMOUNT();

    /// @notice Thrown when input amount is excessive
    error EXCESSIVE_INPUT_AMOUNT();

    /// @notice Thrown when ETH transfer fails
    error ETH_TRANSFER_FAILED();

    /// @notice Thrown when reserves are invalid
    error INVALID_RESERVES();

    /*//////////////////////////////////////////////////////////////
                            MINTER ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when epoch 0 has already started
    error STARTED();

    /// @notice Thrown when emissions haven't started
    error EMISSIONS_NOT_STARTED();

    /// @notice Thrown when deviation is too high
    error TOO_HIGH();

    /// @notice Thrown when no value change detected
    error NO_CHANGE();

    /// @notice Thrown when updating emissions in same period
    error SAME_PERIOD();

    /// @notice Thrown when contract setup is invalid
    error INVALID_CONTRACT();

    /// @notice Thrown when legacy factory doesn't have feeSplitWhenNoGauge on
    error FEE_SPLIT_WHEN_NO_GAUGE_IS_OFF();

    /*//////////////////////////////////////////////////////////////
                        ACCESS HUB ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when addresses are identical
    error SAME_ADDRESS();

    /// @notice Thrown when caller is not timelock
    /// @param caller The invalid caller address
    error NOT_TIMELOCK(address caller);

    /// @notice Thrown when manual execution fails
    /// @param reason The failure reason
    error MANUAL_EXECUTION_FAILURE(bytes reason);

    /// @notice Thrown when kick operation is forbidden
    /// @param target The target address
    error KICK_FORBIDDEN(address target);

    /// @notice Thrown when the function called on AccessHub is not found
    error FUNCTION_NOT_FOUND();

    /// @notice Thrown when the expansion pack can't be added
    error FAILED_TO_ADD();

    /// @notice Thrown when the expansion pack can't be removed
    error FAILED_TO_REMOVE();

    /// @notice Throw when someone other than x33Adapter calls rebaseX33Callback
    error NOT_X33_ADAPTER();

    /*//////////////////////////////////////////////////////////////
                        VOTE MODULE ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not xRam
    error NOT_XRAM();

    /// @notice Thrown when cooldown period is still active
    error COOLDOWN_ACTIVE();

    /// @notice Thrown when caller is not vote module
    error NOT_VOTEMODULE();

    /// @notice Thrown when caller is unauthorized
    error UNAUTHORIZED();

    /// @notice Thrown when caller is not access hub
    error NOT_ACCESSHUB();

    /// @notice Thrown when address is invalid
    error INVALID_ADDRESS();
    

    /*//////////////////////////////////////////////////////////////
                            X33 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when value is zero
    error ZERO();

    /// @notice Thrown when amount is insufficient
    error NOT_ENOUGH();

    /// @notice Thrown when value doesn't conform to scale
    /// @param value The non-conforming value
    error NOT_CONFORMED_TO_SCALE(uint256 value);

    /// @notice Thrown when contract is locked
    error LOCKED();

    /// @notice Thrown when rebase is in progress
    error REBASE_IN_PROGRESS();

    /// @notice Thrown when aggregator reverts
    /// @param reason The revert reason
    error AGGREGATOR_REVERTED(bytes reason);

    /// @notice Thrown when output amount is too low
    /// @param amount The insufficient amount
    error AMOUNT_OUT_TOO_LOW(uint256 amount);

    /// @notice Thrown when aggregator is not whitelisted
    /// @param aggregator The non-whitelisted aggregator address
    error AGGREGATOR_NOT_WHITELISTED(address aggregator);

    /// @notice Thrown when token is forbidden
    /// @param token The forbidden token address
    error FORBIDDEN_TOKEN(address token);

    /*//////////////////////////////////////////////////////////////
                            XRAM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when caller is not minter
    error NOT_MINTER();

    /// @notice Thrown when no vest exists
    error NO_VEST();

    /// @notice Thrown when already exempt
    error ALREADY_EXEMPT();

    /// @notice Thrown when not exempt
    error NOT_EXEMPT();

    /// @notice Thrown when rescue operation is not allowed
    error CANT_RESCUE();

    /// @notice Thrown when array lengths mismatch
    error ARRAY_LENGTHS();

    /// @notice Thrown when vesting periods overlap
    error VEST_OVERLAP();

    /*//////////////////////////////////////////////////////////////
                            V3 FACTORY ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when tokens are identical
    error IDENTICAL_TOKENS();

    /// @notice Thrown when fee is too large
    error FEE_TOO_LARGE();

    /// @notice Address zero error
    error ADDRESS_ZERO();

    /// @notice Fee zero error
    error F0();

    /// @notice Thrown when value is out of bounds
    /// @param value The out of bounds value
    error OOB(uint8 value);

}
