// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAutoVault
/// @notice Interface for AutoVault multi-output xRAM staking vault
interface IAutoVault {
    // ═══════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Parameters for executing a swap via aggregator
    /// @param aggregator Address of the whitelisted aggregator
    /// @param tokenIn Input token to swap (for budget tracking)
    /// @param callData Encoded swap calldata for aggregator (includes slippage protection)
    struct AggregatorParams {
        address aggregator;
        address tokenIn;
        bytes callData;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when user deposits xRAM
    event Deposit(address indexed user, uint256 amount, address indexed outputToken);

    /// @notice Emitted when user withdraws xRAM
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Emitted when user claims rewards
    event Claimed(address indexed user, address indexed outputToken, uint256 amount);

    /// @notice Emitted when user changes output preference
    event OutputPreferenceChanged(address indexed user, address indexed oldOutput, address indexed newOutput);

    /// @notice Emitted when operator executes a swap
    event SwapExecuted(
        address indexed inputToken,
        address indexed outputToken,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when operator claims incentives
    event IncentivesClaimed(address[] feeDistributors);

    /// @notice Emitted when operator unlocks the period
    event Unlocked(uint256 indexed period);

    /// @notice Emitted when operator locks the period
    event LockedByOperator(uint256 indexed period);

    /// @notice Emitted when operator submits votes
    event VotesSubmitted(address[] pools, uint256[] weights);

    /// @notice Emitted when input budget is allocated across outputs
    event InputBudgetAllocated(address indexed inputToken, uint256 amount);

    /// @notice Emitted when an LP token is unwrapped into underlying tokens
    event LPUnwrapped(address indexed lpToken, address token0, address token1, uint256 amount0, uint256 amount1);

    /// @notice Emitted when output token is added to whitelist
    event OutputTokenAdded(address indexed token);

    /// @notice Emitted when output token is removed from whitelist
    event OutputTokenRemoved(address indexed token);

    /// @notice Emitted when aggregator is added to whitelist
    event AggregatorAdded(address indexed aggregator);

    /// @notice Emitted when aggregator is removed from whitelist
    event AggregatorRemoved(address indexed aggregator);

    /// @notice Emitted when operator is changed
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);

    /// @notice Emitted when tokens are rescued
    event Rescued(address indexed token, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Thrown when caller is not the operator
    error NotOperator();

    /// @notice Thrown when caller is not AccessHub
    error NotAccessHub();

    /// @notice Thrown when vault is locked
    error Locked();

    /// @notice Thrown when vault is not locked
    error NotLocked();

    /// @notice Thrown when deposit below minimum (1 xRAM)
    error DepositTooSmall();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when user has insufficient balance
    error InsufficientBalance();

    /// @notice Thrown when user has zero balance
    error ZeroBalance();

    /// @notice Thrown when output token is not whitelisted
    error InvalidOutput();

    /// @notice Thrown when aggregator is not whitelisted
    error AggregatorNotWhitelisted();

    /// @notice Thrown when aggregator call fails
    error AggregatorReverted(bytes reason);

    /// @notice Thrown when swap produced no output (wrong swap direction)
    error NoOutputReceived();

    /// @notice Thrown when output token has no stakers
    error NoStakersForOutput();

    /// @notice Thrown when trying to remove output with unswapped budgets (use force=true to override)
    error OutputHasBudget();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when already initialized
    error AlreadyInitialized();

    /// @notice Thrown when trying to unlock with pending swaps (guarded mode)
    error SwapsNotFinished();

    /// @notice Thrown when deposits in voteModule were touched during swap (should never happen)
    error HowDidYouDoThis();

    // ═══════════════════════════════════════════════════════════════════════
    // USER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deposit xRAM and select output token preference
    /// @param amount Amount of xRAM to deposit
    /// @param outputToken Preferred output token for rewards
    function deposit(uint256 amount, address outputToken) external;

    /// @notice Withdraw xRAM from vault
    /// @param amount Amount of xRAM to withdraw
    function withdraw(uint256 amount) external;

    /// @notice Claim pending rewards
    function claim() external;

    /// @notice Change output token preference
    /// @param newOutput New output token preference
    function setOutputPreference(address newOutput) external;

    // ═══════════════════════════════════════════════════════════════════════
    // OPERATOR FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Submit votes for pools
    /// @param pools Array of pool addresses to vote for
    /// @param weights Array of vote weights
    function submitVotes(address[] calldata pools, uint256[] calldata weights) external;

    /// @notice Claim incentives and auto-allocate input budgets
    /// @param feeDistributors Array of fee distributor addresses
    /// @param tokens Array of token arrays to claim from each distributor
    function claimIncentives(
        address[] calldata feeDistributors,
        address[][] calldata tokens
    ) external;

    /// @notice Swap input token to output token via whitelisted aggregator
    /// @param outputToken Target output token
    /// @param params Aggregator swap parameters
    function swap(address outputToken, AggregatorParams calldata params) external;

    /// @notice Unlock current period for deposits/withdrawals
    /// @param guarded If true, reverts if there are pending swaps
    function unlock(bool guarded) external;

    /// @notice Lock current period (disable deposits/withdrawals)
    function lock() external;

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS (AccessHub only)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Add output token to whitelist
    /// @param token Token address to add
    function addOutputToken(address token) external;

    /// @notice Remove output token from whitelist
    /// @param token Token address to remove
    /// @param force If true, wipes orphaned budgets instead of reverting
    function removeOutputToken(address token, bool force) external;

    /// @notice Add aggregator to whitelist
    /// @param aggregator Aggregator address to add
    function addAggregator(address aggregator) external;

    /// @notice Remove aggregator from whitelist
    /// @param aggregator Aggregator address to remove
    function removeAggregator(address aggregator) external;

    /// @notice Set new operator
    /// @param newOperator New operator address
    function setOperator(address newOperator) external;

    /// @notice Rescue stuck tokens (not xRAM)
    /// @param token Token to rescue
    /// @param amount Amount to rescue
    function rescue(address token, uint256 amount) external;

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Get current period (epoch)
    /// @return period Current period number
    function getPeriod() external view returns (uint256 period);

    /// @notice Check if vault is unlocked for deposits/withdrawals
    /// @return unlocked True if unlocked
    function isUnlocked() external view returns (bool unlocked);

    /// @notice Get accumulated reward per token for output
    /// @param output Output token address
    /// @return accumulated Accumulated reward per token
    function rewardPerToken(address output) external view returns (uint256 accumulated);

    /// @notice Get pending rewards for user
    /// @param user User address
    /// @return pending Pending reward amount
    function earned(address user) external view returns (uint256 pending);

    /// @notice Get user's xRAM balance
    /// @param user User address
    /// @return balance User balance
    function balanceOf(address user) external view returns (uint256 balance);

    /// @notice Get total xRAM staked
    /// @return total Total supply
    function totalSupply() external view returns (uint256 total);

    /// @notice Get user's output preference
    /// @param user User address
    /// @return output Output token address
    function outputPreference(address user) external view returns (address output);

    /// @notice Get total staked for output token
    /// @param output Output token address
    /// @return total Total staked
    function totalSupplyPerOutput(address output) external view returns (uint256 total);

    /// @notice Get list of whitelisted output tokens
    /// @return tokens Array of output token addresses
    function getOutputTokens() external view returns (address[] memory tokens);

    /// @notice Get list of whitelisted aggregators
    /// @return aggregators Array of aggregator addresses
    function getAggregators() external view returns (address[] memory aggregators);

    /// @notice Get remaining input budget for a specific input-output pair
    /// @param inputToken Input token address
    /// @param outputToken Output token address
    /// @return remaining Remaining budget
    function getInputBudget(address inputToken, address outputToken) external view returns (uint256 remaining);

    /// @notice Get operator address
    function OPERATOR() external view returns (address);

    /// @notice Get xRAM address
    function XRAM() external view returns (address);

    /// @notice Get VoteModule address
    function VOTE_MODULE() external view returns (address);

    /// @notice Get Voter address
    function VOTER() external view returns (address);

    /// @notice Get AccessHub address
    function ACCESS_HUB() external view returns (address);

    /// @notice Get legacy router address (for LP unwrapping)
    function LEGACY_ROUTER() external view returns (address);

    /// @notice Get list of all input tokens that have been claimed (for operator enumeration)
    /// @return tokens Array of input token addresses with non-zero budgets
    function getClaimedInputTokens() external view returns (address[] memory tokens);

    /// @notice Get count of pending swaps (non-zero budgets)
    /// @return count Number of input-output pairs with non-zero budgets
    function pendingSwapCount() external view returns (uint256 count);

    /// @notice Get all pending swaps (non-zero input budgets) for operator
    /// @return inputTokens Array of input token addresses
    /// @return outputTokens Array of output token addresses
    /// @return amounts Array of budget amounts
    function getPendingSwaps()
        external
        view
        returns (address[] memory inputTokens, address[] memory outputTokens, uint256[] memory amounts);

    /// @notice Get pending swaps with pagination (for large token sets)
    /// @param startIdx Starting index in the flattened list
    /// @param maxResults Maximum number of results to return
    /// @return inputTokens Array of input token addresses
    /// @return outputTokens Array of output token addresses
    /// @return amounts Array of budget amounts
    function getPendingSwapsPaginated(uint256 startIdx, uint256 maxResults)
        external
        view
        returns (address[] memory inputTokens, address[] memory outputTokens, uint256[] memory amounts);
}
