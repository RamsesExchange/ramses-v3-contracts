// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IXRam} from "contracts/interfaces/IXRam.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {IAccessHub} from "contracts/interfaces/IAccessHub.sol";
import {IVoteModule} from "contracts/interfaces/IVoteModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVoter} from "contracts/interfaces/IVoter.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPair} from "contracts/interfaces/IPair.sol";
import {IRouter} from "contracts/interfaces/IRouter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAutoVault} from "contracts/autovault/interfaces/IAutoVault.sol";
contract RamsesTreasuryHelper is Initializable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    /// @dev ERRORS
    // authorization errors
    error NotTimelock(address caller);
    error NotTreasury(address caller);
    error NotOperator(address caller);
    error NotMember(address account);
    // input validation errors
    error NotLP(address token);
    error InvalidAddress();
    error InvalidWeight(uint256 weight);
    error InvalidTotalWeight(uint256 total);
    error ZeroAddress();
    error ZeroAmount();
    // state errors
    error InvalidAggregator(address aggregator);
    error NoMembers();
    error NoBalance();
    error WARNING();
    // transaction errors
    error TransferFailed();
    error CallFailed();
    error AggregatorFailed(bytes returnData);
    error InsufficientOutput(uint256 received, uint256 minimum);
    error GotLessThanExpected();
    /// @dev STATE
    // globals
    struct Storage {
        uint256 BASIS_POINTS;
        // AccessHub is the single source of truth for ALL protocol contracts
        IAccessHub accessHub;
        // config (treasury-specific)
        address operator;
        address legacyRouter;
        mapping(address => bool) whitelistedAggregators;
        EnumerableMap.AddressToUintMap memberWeights;
        uint256 totalWeight;
    }

    //keccak256(abi.encode(uint256(keccak256("ram.treasury.manager.helper.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant STORAGE_LOCATION = 0xacb1ad4144b50fefb1895703d57807b08cda0f602f2d3e0d88f68fb649911100;
    /// @dev Return state storage struct for reading and writing
    function getStorage() internal pure returns (Storage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }
    /// @dev STRUCTS

    struct AggregatorParams {
        address _aggregator;
        address _tokenIn;
        address _tokenOut;
        uint256 _amountIn;
        uint256 _minAmountOut;
        bytes _callData;
    }
    /// @dev EVENTS

    event MemberUpdated(address account, uint256 weight);
    event Distribution(address indexed member, address indexed token, uint256 amount);
    event SwappedIncentive(address indexed tokenIn, uint256 amountIn, uint256 amountOut);
    event AggregatorWhitelistUpdated(address aggregator, bool status);
    event Voted(address[] pools, uint256[] weights);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _accessHub,
        address _initialOperator,
        address _legacyRouter
    ) public initializer {
        if (_accessHub == address(0)) revert ZeroAddress();
        if (_initialOperator == address(0)) revert ZeroAddress();
        if (_legacyRouter == address(0)) revert ZeroAddress();

        Storage storage $ = getStorage();
        $.BASIS_POINTS = 10000;
        $.accessHub = IAccessHub(_accessHub);
        $.operator = _initialOperator;
        $.legacyRouter = _legacyRouter;
    }

    /// @dev MODIFIERS

    modifier onlyTimelock() {
        Storage storage $ = getStorage();
        if (msg.sender != $.accessHub.timelock()) revert NotTimelock(msg.sender);
        _;
    }

    modifier onlyTreasury() {
        Storage storage $ = getStorage();
        if (msg.sender != $.accessHub.treasury()) revert NotTreasury(msg.sender);
        _;
    }

    modifier onlyOperator() {
        Storage storage $ = getStorage();
        if (msg.sender != $.operator) revert NotOperator(msg.sender);
        _;
    }

    modifier onlyOperatorOrTreasury() {
        Storage storage $ = getStorage();
        if (msg.sender != $.operator && msg.sender != $.accessHub.treasury()) revert NotOperator(msg.sender);
        _;
    }

    modifier guarded() {
        Storage storage $ = getStorage();
        IVoteModule voteModule = IVoteModule($.accessHub.voteModule());
        uint256 stakedBalanceBefore = voteModule.balanceOf(address(this));
        _;
        uint256 stakedBalanceAfter = voteModule.balanceOf(address(this));
        if (stakedBalanceAfter < stakedBalanceBefore) revert WARNING();
    }

    /// @dev MANAGEMENT
    function updateMember(address _account, uint256 _weight) external onlyTreasury {
        Storage storage $ = getStorage();
        if (_account == address(0)) revert InvalidAddress();
        if (_weight > $.BASIS_POINTS) revert InvalidWeight(_weight);

        if ($.memberWeights.contains(_account)) {
            uint256 oldWeight = $.memberWeights.get(_account);
            $.totalWeight -= oldWeight;
        }
        $.totalWeight += _weight;
        if ($.totalWeight > $.BASIS_POINTS) revert InvalidTotalWeight($.totalWeight);
        if (_weight > 0) {
            $.memberWeights.set(_account, _weight);
        } else {
            $.memberWeights.remove(_account);
        }
        emit MemberUpdated(_account, _weight);
    }

    function updateOperator(address _newOperator) external onlyTreasury {
        Storage storage $ = getStorage();
        if (_newOperator == address(0)) revert ZeroAddress();
        $.operator = _newOperator;
    }

    /// @dev TREASURY OPERATIONS
    function depositXRam(uint256 _amount) external onlyTreasury {
        Storage storage $ = getStorage();
        if (_amount == 0) revert ZeroAmount();
        IXRam xRam = IXRam($.accessHub.xRam());
        IVoteModule voteModule = IVoteModule($.accessHub.voteModule());
        xRam.approve(address(voteModule), _amount);
        voteModule.deposit(_amount);
    }

    function withdrawXRam(uint256 _amount) external onlyTreasury {
        Storage storage $ = getStorage();
        if (_amount == 0) revert ZeroAmount();
        IVoteModule voteModule = IVoteModule($.accessHub.voteModule());
        voteModule.withdraw(_amount);
        if (IERC20($.accessHub.xRam()).balanceOf(address(this)) < _amount) revert GotLessThanExpected();
    }

    /// @dev OPERATOR UPKEEP
    function compound() external onlyOperator {
        Storage storage $ = getStorage();
        IXRam xRam = IXRam($.accessHub.xRam());
        IERC20 ram = IERC20(xRam.RAM());

        // 1. convert RAM -> xRAM
        uint256 ramBalance = IERC20(ram).balanceOf(address(this));
        if (ramBalance > 0) {
            IERC20(ram).approve(address(xRam), ramBalance);
            xRam.convertEmissionsToken(ramBalance);
        }

        // 2. redeem p33 -> xRAM
        IERC4626 r33 = IERC4626(address($.accessHub.r33()));
        uint256 r33Balance = r33.balanceOf(address(this));
        if (r33Balance > 0) {
            r33.redeem(r33Balance, address(this), address(this));
        }

        // 3. deposit all xRAM -> voteModule
        IVoteModule voteModule = IVoteModule($.accessHub.voteModule());
        uint256 xRamBalance = IERC20(address(xRam)).balanceOf(address(this));
        if (xRamBalance > 0) {
            IERC20(address(xRam)).approve(address(voteModule), xRamBalance);
            voteModule.depositAll();
        }
    }

    function claimIncentives(address[] calldata _feeDistributors, address[][] calldata _tokens) external onlyOperator {
        Storage storage $ = getStorage();
        IVoter voter = IVoter($.accessHub.voter());
        voter.claimIncentives(address(this), _feeDistributors, _tokens);
    }

    /// @notice Allows the operator to cast votes on behalf of the treasury
    /// @param _pools Array of pool addresses to vote for
    /// @param _weights Array of corresponding weights for each pool
    function submitVotes(address[] calldata _pools, uint256[] calldata _weights) external onlyOperator {
        Storage storage $ = getStorage();
        IVoter voter = IVoter($.accessHub.voter());
        // Call the vote function on the voter contract, casting votes from this contract's address
        voter.vote(address(this), _pools, _weights);
        emit Voted(_pools, _weights);
    }

    function swapIncentiveViaAggregator(AggregatorParams calldata _params) external onlyOperator guarded {
        Storage storage $ = getStorage();
        if (!$.whitelistedAggregators[_params._aggregator]) revert InvalidAggregator(_params._aggregator);

        // swap via aggregator
        uint256 balanceBefore = IERC20(_params._tokenOut).balanceOf(address(this));
        IERC20(_params._tokenIn).approve(_params._aggregator, _params._amountIn);
        (bool success, bytes memory returnData) = _params._aggregator.call(_params._callData);
        if (!success) revert AggregatorFailed(returnData);

        // validate slippage
        uint256 balanceAfter = IERC20(_params._tokenOut).balanceOf(address(this));
        uint256 received = balanceAfter - balanceBefore;
        if (received < _params._minAmountOut) revert InsufficientOutput(received, _params._minAmountOut);

        emit SwappedIncentive(_params._tokenIn, _params._amountIn, received);
    }

    /// @notice try to unwrap LP token to token0/1
    /// @param token LP token address
    /// @return isLP bool if its a LP token
    /// @return tokenA token0 address
    /// @return tokenB token1 address
    function _tryUnwrapLP(address token) internal returns (bool isLP, address tokenA, address tokenB) {
        Storage storage $ = getStorage();
        try IPair(token).token0() returns (address token0) {
            address token1 = IPair(token).token1();
            uint256 lpBalance = IERC20(token).balanceOf(address(this));

            if (lpBalance > 0) {
                // approve legacy router to spend LP tokens
                IERC20(token).approve($.legacyRouter, lpBalance);
                // remove liquidity
                IRouter($.legacyRouter).removeLiquidity(
                    token0,
                    token1,
                    IPair(token).stable(),
                    lpBalance,
                    0, // amountAMin
                    0, // amountBMin
                    address(this),
                    block.timestamp
                );

                return (true, token0, token1);
            }
        } catch {
            return (false, address(0), address(0));
        }
    }

    function tryUnwrapLP(address token) external onlyOperator guarded {
        (bool isLP, , ) = _tryUnwrapLP(token);
        if (!isLP) revert NotLP(token);
    }


    function whitelistAggregator(address _aggregator, bool _status) external onlyTreasury {
        Storage storage $ = getStorage();
        $.whitelistedAggregators[_aggregator] = _status;
        emit AggregatorWhitelistUpdated(_aggregator, _status);
    }

    function distribute(address _token) external onlyOperatorOrTreasury {
        Storage storage $ = getStorage();
        if ($.memberWeights.length() == 0) revert NoMembers();
        if (_token == address(0)) revert ZeroAddress();

        // don't distribute unless all members been defined allocation
        if ($.totalWeight != $.BASIS_POINTS) revert InvalidTotalWeight($.totalWeight);

        // claim any pending autovault rewards before distributing
        IAutoVault vault = $.accessHub.autoVault();
        if (address(vault) != address(0) && vault.earned(address(this)) > 0) {
            vault.claim();
        }

        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert NoBalance();

        for (uint256 i = 0; i < $.memberWeights.length(); i++) {
            (address account, uint256 weight) = $.memberWeights.at(i);
            uint256 share = (balance * weight) / $.BASIS_POINTS;
            if (share > 0) {
                bool success = IERC20(_token).transfer(account, share);
                if (account == address(0)) revert ZeroAddress();
                if (!success) revert TransferFailed();
                emit Distribution(account, _token, share);
            }
        }
    }


    /// @dev VIEW FUNCTIONS
    function getMemberWeight(address _account) external view returns (uint256) {
        Storage storage $ = getStorage();
        require($.memberWeights.contains(_account), NotMember(_account));
        return $.memberWeights.get(_account);
    }

    function getMemberCount() external view returns (uint256) {
        Storage storage $ = getStorage();
        return $.memberWeights.length();
    }

    function getAllMembers() external view returns (address[] memory accounts, uint256[] memory weights) {
        Storage storage $ = getStorage();
        uint256 length = $.memberWeights.length();
        accounts = new address[](length);
        weights = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            (accounts[i], weights[i]) = $.memberWeights.at(i);
        }

        return (accounts, weights);
    }

    function treasuryVotingPower() external view returns (uint256) {
        Storage storage $ = getStorage();
        IXRam xRam = IXRam($.accessHub.xRam());
        IVoteModule voteModule = IVoteModule($.accessHub.voteModule());
        uint256 totalVotingPower =
            voteModule.balanceOf(address(this)) +
            xRam.balanceOf(address(this));
        uint256 totalSupply = xRam.totalSupply();
        return totalVotingPower * 1e18 / totalSupply;
    }

    /// @dev AUTOVAULT OPERATIONS
    function autoVaultDeposit(uint256 _amount, address _outputToken) external onlyTreasury {
        Storage storage $ = getStorage();
        if (_amount == 0) revert ZeroAmount();
        IAutoVault vault = $.accessHub.autoVault();
        IERC20($.accessHub.xRam()).approve(address(vault), _amount);
        vault.deposit(_amount, _outputToken);
    }

    function autoVaultWithdraw(uint256 _amount) external onlyTreasury {
        if (_amount == 0) revert ZeroAmount();
        Storage storage $ = getStorage();
        $.accessHub.autoVault().withdraw(_amount);
    }

    function autoVaultClaim() external onlyTreasury {
        Storage storage $ = getStorage();
        $.accessHub.autoVault().claim();
    }

    /// @dev SAFETY FUNCTIONS
    function recoverERC20(address _token, uint256 _amount) external onlyTreasury {
        Storage storage $ = getStorage();
        IERC20(_token).transfer($.accessHub.treasury(), _amount);
    }

    function recoverERC20Full(address _token) external onlyTreasury {
        Storage storage $ = getStorage();
        IERC20(_token).transfer($.accessHub.treasury(), IERC20(_token).balanceOf(address(this)));
    }

    function recoverNative() external onlyTreasury {
        Storage storage $ = getStorage();
        (bool success,) = $.accessHub.treasury().call{value: address(this).balance}("");
        if (!success) revert TransferFailed();
    }

    function emergencyExecute(address _to, bytes calldata _data) external onlyTimelock {
        if (_to == address(0)) revert ZeroAddress();
        (bool success,) = _to.call(_data);
        if (!success) revert CallFailed();
    }

    function clawBackToTreasury(address _token, uint256 _amount) external onlyOperator {
        Storage storage $ = getStorage();
        IERC20(_token).transfer($.accessHub.treasury(), _amount);
    }

    /// @dev VIEW FUNCTIONS FOR STORAGE VARIABLES
    function getXRam() external view returns (address) {
        Storage storage $ = getStorage();
        return address($.accessHub.xRam());
    }
    function getVoteModule() external view returns (address) {
        Storage storage $ = getStorage();
        return address($.accessHub.voteModule());
    }
    function getTreasury() external view returns (address) {
        Storage storage $ = getStorage();
        return $.accessHub.treasury();
    }
    function getTimelock() external view returns (address) {
        Storage storage $ = getStorage();
        return $.accessHub.timelock();
    }
    function getVoter() external view returns (address) {
        Storage storage $ = getStorage();
        return address($.accessHub.voter());
    }
    function getOperator() external view returns (address) {
        Storage storage $ = getStorage();
        return $.operator;
    }
    function isAggregatorWhitelisted(address _aggregator) external view returns (bool) {
        Storage storage $ = getStorage();
        return $.whitelistedAggregators[_aggregator];
    }
    function getTotalWeight() external view returns (uint256) {
        Storage storage $ = getStorage();
        return $.totalWeight;
    }
    function getLegacyRouter() external view returns (address) {
        Storage storage $ = getStorage();
        return $.legacyRouter;
    }

    function getBasisPoints() external view returns (uint256) {
        Storage storage $ = getStorage();
        return $.BASIS_POINTS;
    }

    function getAccessHub() external view returns (address) {
        Storage storage $ = getStorage();
        return address($.accessHub);
    }
}
