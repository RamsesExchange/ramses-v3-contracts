// SPDX-License-Identifier: kBUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {AutoVaultStorage} from "./AutoVaultStorage.sol";
import {IAutoVault} from "./interfaces/IAutoVault.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVoteModule} from "../interfaces/IVoteModule.sol";
import {IPairFactory} from "../interfaces/IPairFactory.sol";
import {IPair} from "../interfaces/IPair.sol";
import {IRouter} from "../interfaces/IRouter.sol";

/// @title AutoVault
/// @notice Multi-output xRAM staking vault
/// @dev Users stake xRAM, choose output token preference, operator swaps rewards proportionally
contract AutoVault is IAutoVault, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    uint256 private constant PRECISION = 1e27;
    uint256 private constant WEEK = 1 weeks;
    uint256 private constant LOCK_BUFFER = 1 hours;
    uint256 private constant MIN_DEPOSIT = 1e18; // 1 xRAM

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyOperator() {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        if (msg.sender != $.operator && msg.sender != $.accessHub) revert NotOperator();
        _;
    }

    modifier onlyAccessHub() {
        if (msg.sender != AutoVaultStorage.layout().accessHub) revert NotAccessHub();
        _;
    }

    modifier whileUnlocked() {
        if (!isUnlocked()) revert Locked();
        _;
    }

    modifier whileLocked() {
        if (isUnlocked()) revert NotLocked();
        _;
    }

    modifier updateReward(address user) {
        _updateReward(user);
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initialize the AutoVault
    /// @param _xRam xRAM token address
    /// @param _voteModule VoteModule contract address
    /// @param _voter Voter contract address
    /// @param _accessHub AccessHub contract address
    /// @param _operator Initial operator address
    /// @param _legacyRouter Legacy router address for LP unwrapping
    function initialize(
        address _xRam,
        address _voteModule,
        address _voter,
        address _accessHub,
        address _operator,
        address _legacyRouter
    ) external initializer {
        if (_xRam == address(0)) revert ZeroAddress();
        if (_voteModule == address(0)) revert ZeroAddress();
        if (_voter == address(0)) revert ZeroAddress();
        if (_accessHub == address(0)) revert ZeroAddress();
        if (_operator == address(0)) revert ZeroAddress();
        if (_legacyRouter == address(0)) revert ZeroAddress();

        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        $.xRam = _xRam;
        $.voteModule = _voteModule;
        $.voter = _voter;
        $.accessHub = _accessHub;
        $.operator = _operator;
        $.legacyRouter = _legacyRouter;

        // pre-approve xRAM to voteModule
        IERC20(_xRam).approve(_voteModule, type(uint256).max);

        // unlock initial period
        $.periodUnlockStatus[getPeriod()] = true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // USER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAutoVault
    function deposit(uint256 amount, address outputToken) external whileUnlocked updateReward(msg.sender) nonReentrant {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        if (amount < MIN_DEPOSIT) revert DepositTooSmall();
        if (!$.outputTokens.contains(outputToken)) revert InvalidOutput();

        address oldOutput = $.outputPreference[msg.sender];

        // handle output switch or new user
        if (oldOutput != address(0) && oldOutput != outputToken) {
            _switchOutput(msg.sender, oldOutput, outputToken);
        } else if (oldOutput == address(0)) {
            $.userRewardPerTokenPaid[msg.sender] = $.rewardPerTokenStored[outputToken];
        }

        // update state
        $.balanceOf[msg.sender] += amount;
        $.totalSupply += amount;
        $.outputPreference[msg.sender] = outputToken;
        $.totalSupplyPerOutput[outputToken] += amount;

        // transfer xRAM and deposit to voteModule
        IERC20($.xRam).safeTransferFrom(msg.sender, address(this), amount);
        IVoteModule($.voteModule).deposit(amount);

        emit Deposit(msg.sender, amount, outputToken);
    }

    /// @inheritdoc IAutoVault
    function withdraw(uint256 amount) external whileUnlocked updateReward(msg.sender) nonReentrant {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        if (amount == 0) revert ZeroAmount();
        if ($.balanceOf[msg.sender] < amount) revert InsufficientBalance();

        address output = $.outputPreference[msg.sender];

        // update state
        $.balanceOf[msg.sender] -= amount;
        $.totalSupply -= amount;
        $.totalSupplyPerOutput[output] -= amount;

        // withdraw from voteModule and transfer xRAM
        IVoteModule($.voteModule).withdraw(amount);
        IERC20($.xRam).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    /// @inheritdoc IAutoVault
    function claim() external whileUnlocked updateReward(msg.sender) nonReentrant {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        uint256 reward = $.storedRewards[msg.sender];
        if (reward > 0) {
            $.storedRewards[msg.sender] = 0;
            address output = $.outputPreference[msg.sender];
            IERC20(output).safeTransfer(msg.sender, reward);

            emit Claimed(msg.sender, output, reward);
        }
    }

    /// @inheritdoc IAutoVault
    function setOutputPreference(address newOutput) external whileUnlocked updateReward(msg.sender) nonReentrant {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        if (!$.outputTokens.contains(newOutput)) revert InvalidOutput();
        if ($.balanceOf[msg.sender] == 0) revert ZeroBalance();

        address oldOutput = $.outputPreference[msg.sender];

        if (oldOutput != newOutput) {
            _switchOutput(msg.sender, oldOutput, newOutput);
            $.outputPreference[msg.sender] = newOutput;
            emit OutputPreferenceChanged(msg.sender, oldOutput, newOutput);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // OPERATOR FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAutoVault
    function submitVotes(address[] calldata pools, uint256[] calldata weights) external onlyOperator {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        IVoter($.voter).vote(address(this), pools, weights);
        emit VotesSubmitted(pools, weights);
    }

    /// @inheritdoc IAutoVault
    function claimIncentives(
        address[] calldata feeDistributors,
        address[][] calldata tokens
    ) external onlyOperator whileLocked {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        // flatten tokens and deduplicate
        uint256 totalTokens;
        for (uint256 i; i < tokens.length; ++i) {
            totalTokens += tokens[i].length;
        }

        address[] memory uniqueTokens = new address[](totalTokens);
        uint256 uniqueCount;

        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < tokens[i].length; ++j) {
                address token = tokens[i][j];
                bool isDuplicate;
                for (uint256 k; k < uniqueCount; ++k) {
                    if (uniqueTokens[k] == token) {
                        isDuplicate = true;
                        break;
                    }
                }
                if (!isDuplicate) {
                    uniqueTokens[uniqueCount++] = token;
                }
            }
        }

        // snapshot balances before claim
        uint256[] memory balancesBefore = new uint256[](uniqueCount);
        for (uint256 i; i < uniqueCount; ++i) {
            balancesBefore[i] = IERC20(uniqueTokens[i]).balanceOf(address(this));
        }

        // claim from voter
        IVoter($.voter).claimIncentives(address(this), feeDistributors, tokens);

        // get pairFactory from legacyRouter to validate LPs
        IPairFactory pairFactory = IPairFactory(IRouter($.legacyRouter).factory());

        // measure received amounts once (before any unwrapping)
        uint256[] memory received = new uint256[](uniqueCount);
        for (uint256 i; i < uniqueCount; ++i) {
            received[i] = IERC20(uniqueTokens[i]).balanceOf(address(this)) - balancesBefore[i];
        }

        // allocate budgets based on received amounts
        // if token is an LP, unwrap it and allocate the underlying tokens instead
        for (uint256 i; i < uniqueCount; ++i) {
            uint256 amount = received[i];
            if (amount == 0) continue;

            address token = uniqueTokens[i];
            if (pairFactory.isPair(token)) {
                // unwrap LP and allocate underlying tokens
                (address token0, address token1, uint256 amount0, uint256 amount1) = _unwrapLP(token, amount);
                if (amount0 > 0) {
                    _allocateInputBudget(token0, amount0);
                }
                if (amount1 > 0) {
                    _allocateInputBudget(token1, amount1);
                }
                emit LPUnwrapped(token, token0, token1, amount0, amount1);
            } else {
                // regular token, allocate directly
                _allocateInputBudget(token, amount);
            }
        }

        emit IncentivesClaimed(feeDistributors);
    }

    function _unwrapLP(
        address lpToken,
        uint256 amount
    ) internal returns (address token0, address token1, uint256 amount0, uint256 amount1) {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        token0 = IPair(lpToken).token0();
        token1 = IPair(lpToken).token1();
        bool stable = IPair(lpToken).stable();

        // approve router to spend LP
        IERC20(lpToken).forceApprove($.legacyRouter, amount);

        // remove liquidity
        (amount0, amount1) = IRouter($.legacyRouter).removeLiquidity(
            token0,
            token1,
            stable,
            amount,
            0, // amountAMin - no slippage protection needed, we want all underlying
            0, // amountBMin
            address(this),
            block.timestamp
        );
    }

    /// @inheritdoc IAutoVault
    function swap(address outputToken, AggregatorParams calldata params) external onlyOperator nonReentrant {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        if (!$.aggregators.contains(params.aggregator)) revert AggregatorNotWhitelisted();
        if (!$.outputTokens.contains(outputToken)) revert InvalidOutput();

        uint256 outputSupply = $.totalSupplyPerOutput[outputToken];
        if (outputSupply == 0) revert NoStakersForOutput();

        // cache deposits for the invariant check below
        uint256 depositsBefore = IVoteModule($.voteModule).balanceOf(address(this));

        // snapshot balances before swap
        uint256 inputBefore = IERC20(params.tokenIn).balanceOf(address(this));
        uint256 outputBefore = IERC20(outputToken).balanceOf(address(this));

        // approve up to the budget for this input-output pair (aggregator can't spend more)
        uint256 budget = $.inputBudget[params.tokenIn][outputToken];
        IERC20(params.tokenIn).forceApprove(params.aggregator, budget);

        (bool success, bytes memory returnData) = params.aggregator.call(params.callData);
        if (!success) revert AggregatorReverted(returnData);

        // revoke any remaining allowance
        IERC20(params.tokenIn).forceApprove(params.aggregator, 0);

        // measure actual amounts from balance deltas
        uint256 inputSpent = inputBefore - IERC20(params.tokenIn).balanceOf(address(this));
        uint256 outputReceived = IERC20(outputToken).balanceOf(address(this)) - outputBefore;

        // sanity check: output must have increased (operator swapped to correct token)
        if (outputReceived == 0) revert NoOutputReceived();

        // decrement budget by actual input spent
        $.inputBudget[params.tokenIn][outputToken] = budget - inputSpent;

        // update rewardPerToken for this output
        $.rewardPerTokenStored[outputToken] += (outputReceived * PRECISION) / outputSupply;

        // invariant: voteModule deposits must never decrease during swap
        if (IVoteModule($.voteModule).balanceOf(address(this)) < depositsBefore) revert HowDidYouDoThis();

        emit SwapExecuted(params.tokenIn, outputToken, inputSpent, outputReceived);
    }

    /// @inheritdoc IAutoVault
    function unlock(bool guarded) external onlyOperator {
        if (guarded && pendingSwapCount() != 0) revert SwapsNotFinished();
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        uint256 period = getPeriod();
        $.periodUnlockStatus[period] = true;
        emit Unlocked(period);
    }

    /// @inheritdoc IAutoVault
    function lock() external onlyOperator {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        uint256 period = getPeriod();
        $.periodUnlockStatus[period] = false;
        emit LockedByOperator(period);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAutoVault
    function addOutputToken(address token) external onlyAccessHub {
        if (token == address(0)) revert ZeroAddress();
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        $.outputTokens.add(token);
        emit OutputTokenAdded(token);
    }

    /// @inheritdoc IAutoVault
    function removeOutputToken(address token, bool force) external onlyAccessHub {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        uint256 inputLen = $.claimedInputTokens.length();
        for (uint256 i; i < inputLen; ++i) {
            address input = $.claimedInputTokens.at(i);
            uint256 budget = $.inputBudget[input][token];
            if (budget > 0) {
                if (!force) revert OutputHasBudget();
                delete $.inputBudget[input][token];
            }
        }

        $.outputTokens.remove(token);
        emit OutputTokenRemoved(token);
    }

    /// @inheritdoc IAutoVault
    function addAggregator(address aggregator) external onlyAccessHub {
        if (aggregator == address(0)) revert ZeroAddress();
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        $.aggregators.add(aggregator);
        emit AggregatorAdded(aggregator);
    }

    /// @inheritdoc IAutoVault
    function removeAggregator(address aggregator) external onlyAccessHub {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        $.aggregators.remove(aggregator);
        emit AggregatorRemoved(aggregator);
    }

    /// @inheritdoc IAutoVault
    function setOperator(address newOperator) external onlyAccessHub {
        if (newOperator == address(0)) revert ZeroAddress();
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        address oldOperator = $.operator;
        $.operator = newOperator;
        emit OperatorChanged(oldOperator, newOperator);
    }

    /// @inheritdoc IAutoVault
    function rescue(address token, uint256 amount) external onlyAccessHub nonReentrant {
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Rescued(token, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW - EPOCH
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAutoVault
    function getPeriod() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    /// @inheritdoc IAutoVault
    function isUnlocked() public view returns (bool) {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        uint256 period = getPeriod();
        uint256 timeLeftInPeriod = ((period + 1) * WEEK) - block.timestamp;

        // block deposits/withdrawals 1hr before epoch flip
        if (timeLeftInPeriod <= LOCK_BUFFER) return false;

        return $.periodUnlockStatus[period];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW - USER STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAutoVault
    function balanceOf(address user) external view returns (uint256) {
        return AutoVaultStorage.layout().balanceOf[user];
    }

    /// @inheritdoc IAutoVault
    function totalSupply() external view returns (uint256) {
        return AutoVaultStorage.layout().totalSupply;
    }

    /// @inheritdoc IAutoVault
    function outputPreference(address user) external view returns (address) {
        return AutoVaultStorage.layout().outputPreference[user];
    }

    /// @inheritdoc IAutoVault
    function totalSupplyPerOutput(address output) external view returns (uint256) {
        return AutoVaultStorage.layout().totalSupplyPerOutput[output];
    }

    /// @inheritdoc IAutoVault
    function rewardPerToken(address output) public view returns (uint256) {
        return AutoVaultStorage.layout().rewardPerTokenStored[output];
    }

    /// @inheritdoc IAutoVault
    function earned(address user) public view returns (uint256) {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        address output = $.outputPreference[user];

        if (output == address(0)) return 0;

        return
            (($.balanceOf[user] * (rewardPerToken(output) - $.userRewardPerTokenPaid[user])) / PRECISION) +
            $.storedRewards[user];
    }

    function getStoredRewards(address user) external view returns (uint256) {
        return AutoVaultStorage.layout().storedRewards[user];
    }

    function getUserRewardPerTokenPaid(address user) external view returns (uint256) {
        return AutoVaultStorage.layout().userRewardPerTokenPaid[user];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MIGRATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function batchUpdateReward(address[] calldata users) external {
        for (uint256 i; i < users.length; ++i) {
            _updateReward(users[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW - CONFIG
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAutoVault
    function getOutputTokens() external view returns (address[] memory) {
        return AutoVaultStorage.layout().outputTokens.values();
    }

    /// @inheritdoc IAutoVault
    function getAggregators() external view returns (address[] memory) {
        return AutoVaultStorage.layout().aggregators.values();
    }

    /// @inheritdoc IAutoVault
    function OPERATOR() external view returns (address) {
        return AutoVaultStorage.layout().operator;
    }

    /// @inheritdoc IAutoVault
    function XRAM() external view returns (address) {
        return AutoVaultStorage.layout().xRam;
    }

    /// @inheritdoc IAutoVault
    function VOTE_MODULE() external view returns (address) {
        return AutoVaultStorage.layout().voteModule;
    }

    /// @inheritdoc IAutoVault
    function VOTER() external view returns (address) {
        return AutoVaultStorage.layout().voter;
    }

    /// @inheritdoc IAutoVault
    function ACCESS_HUB() external view returns (address) {
        return AutoVaultStorage.layout().accessHub;
    }

    /// @inheritdoc IAutoVault
    function LEGACY_ROUTER() external view returns (address) {
        return AutoVaultStorage.layout().legacyRouter;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW - OPERATOR LENS
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAutoVault
    function getInputBudget(address inputToken, address outputToken) external view returns (uint256) {
        return AutoVaultStorage.layout().inputBudget[inputToken][outputToken];
    }

    /// @inheritdoc IAutoVault
    function getClaimedInputTokens() external view returns (address[] memory) {
        return AutoVaultStorage.layout().claimedInputTokens.values();
    }

    /// @inheritdoc IAutoVault
    function pendingSwapCount() public view returns (uint256 count) {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        uint256 inputLen = $.claimedInputTokens.length();
        uint256 outputLen = $.outputTokens.length();

        for (uint256 i; i < inputLen; ++i) {
            address input = $.claimedInputTokens.at(i);
            for (uint256 j; j < outputLen; ++j) {
                if ($.inputBudget[input][$.outputTokens.at(j)] > 0) ++count;
            }
        }
    }

    /// @inheritdoc IAutoVault
    function getPendingSwaps()
        external
        view
        returns (address[] memory inputTokens, address[] memory outputTokens, uint256[] memory amounts)
    {
        return getPendingSwapsPaginated(0, type(uint256).max);
    }

    /// @inheritdoc IAutoVault
    function getPendingSwapsPaginated(uint256 startIdx, uint256 maxResults)
        public
        view
        returns (address[] memory inputTokens, address[] memory outputTokens, uint256[] memory amounts)
    {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();

        uint256 inputLen = $.claimedInputTokens.length();
        uint256 outputLen = $.outputTokens.length();

        // first pass: count non-zero budgets
        uint256 totalCount;
        for (uint256 i; i < inputLen; ++i) {
            address input = $.claimedInputTokens.at(i);
            for (uint256 j; j < outputLen; ++j) {
                if ($.inputBudget[input][$.outputTokens.at(j)] > 0) ++totalCount;
            }
        }

        // calculate result size
        uint256 resultCount;
        if (startIdx < totalCount) {
            resultCount = totalCount - startIdx;
            if (resultCount > maxResults) resultCount = maxResults;
        }

        // allocate arrays
        inputTokens = new address[](resultCount);
        outputTokens = new address[](resultCount);
        amounts = new uint256[](resultCount);

        if (resultCount == 0) return (inputTokens, outputTokens, amounts);

        // second pass: fill arrays starting from startIdx
        uint256 currentIdx;
        uint256 resultIdx;
        for (uint256 i; i < inputLen && resultIdx < resultCount; ++i) {
            address input = $.claimedInputTokens.at(i);
            for (uint256 j; j < outputLen && resultIdx < resultCount; ++j) {
                address output = $.outputTokens.at(j);
                uint256 budget = $.inputBudget[input][output];
                if (budget > 0) {
                    if (currentIdx >= startIdx) {
                        inputTokens[resultIdx] = input;
                        outputTokens[resultIdx] = output;
                        amounts[resultIdx] = budget;
                        ++resultIdx;
                    }
                    ++currentIdx;
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    // checkpoint rewards before state changes
    function _updateReward(address user) internal {
        if (user == address(0)) return;
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        address output = $.outputPreference[user];
        if (output == address(0)) return;
        $.storedRewards[user] = earned(user);
        $.userRewardPerTokenPaid[user] = $.rewardPerTokenStored[output];
    }

    // settle rewards + move weight when switching output
    function _switchOutput(address user, address from, address to) internal {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        // settle pending in old token
        uint256 pending = $.storedRewards[user];
        if (pending > 0) {
            $.storedRewards[user] = 0;
            IERC20(from).safeTransfer(user, pending);
            emit Claimed(user, from, pending);
        }
        // move weight
        uint256 bal = $.balanceOf[user];
        $.totalSupplyPerOutput[from] -= bal;
        $.totalSupplyPerOutput[to] += bal;
        // reset checkpoint
        $.userRewardPerTokenPaid[user] = $.rewardPerTokenStored[to];
    }

    // allocate input budget across outputs based on current weights
    function _allocateInputBudget(address inputToken, uint256 amount) internal {
        AutoVaultStorage.Layout storage $ = AutoVaultStorage.layout();
        if ($.totalSupply == 0) return;

        // track this input token for operator enumeration
        $.claimedInputTokens.add(inputToken);

        uint256 len = $.outputTokens.length();
        for (uint256 i; i < len; ++i) {
            address output = $.outputTokens.at(i);
            uint256 weight = $.totalSupplyPerOutput[output];
            uint256 allocation = (amount * weight) / $.totalSupply;

            if (inputToken == output && weight > 0) {
                // direct distribution - no swap needed when input == output
                $.rewardPerTokenStored[output] += (allocation * PRECISION) / weight;
            } else {
                $.inputBudget[inputToken][output] += allocation;
            }
        }

        emit InputBudgetAllocated(inputToken, amount);
    }
}
