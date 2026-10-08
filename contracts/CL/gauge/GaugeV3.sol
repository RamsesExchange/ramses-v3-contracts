// SPDX-License-Identifier: kBUSL-1.1
pragma solidity ^0.8.26;

import {IGaugeV3} from "./interfaces/IGaugeV3.sol";
import {INonfungiblePositionManager} from "../periphery/interfaces/INonfungiblePositionManager.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {IRewardValidator} from "./interfaces/IRewardValidator.sol";
import {FullMath} from "../core/libraries/FullMath.sol";
import {IAccessHub} from "../../interfaces/IAccessHub.sol";

import {IRamsesV3Pool} from "../core/interfaces/IRamsesV3Pool.sol";
import {IRamsesV3PoolState} from "../core/interfaces/pool/IRamsesV3PoolState.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVoter} from "../../interfaces/IVoter.sol";
import {Errors} from "../../libraries/Errors.sol";

contract GaugeV3 is IGaugeV3, Initializable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant WEEK = 1 weeks;
  
    bool internal _unlocked;

    IRamsesV3Pool public pool;
    address public voter;
    IFeeCollector public feeCollector;
    INonfungiblePositionManager public nfpManager;

    /// @inheritdoc IGaugeV3
    uint256 public firstPeriod;

    /// @inheritdoc IGaugeV3
    /// @dev period => token => total supply
    mapping(uint256 => mapping(address => uint256)) public tokenTotalSupplyByPeriod;

    /// @dev period => position hash => bool
    mapping(uint256 => mapping(bytes32 => bool)) internal periodAmountsWritten;
    /// @dev period => position hash => seconds in range
    mapping(uint256 => mapping(bytes32 => uint256)) internal periodNfpSecondsX96;

    /// @inheritdoc IGaugeV3
    /// @dev period => position hash => reward token => amount
    mapping(uint256 => mapping(bytes32 => mapping(address => uint256))) public periodClaimedAmount;

    /// @dev token => position hash => period
    /// @inheritdoc IGaugeV3
    mapping(address => mapping(bytes32 => uint256)) public lastClaimByToken;

    /// @inheritdoc IGaugeV3
    address[] public rewards;
    /// @inheritdoc IGaugeV3
    mapping(address => bool) public isReward;
    
    /// @dev authorized nfpManagers
    EnumerableSet.AddressSet internal authorizedClaimers;
    /// @dev RewardValidator handles the anti-sybil logic
    IRewardValidator public rewardValidator;
    /// @dev Cached r33 address for gas optimization
    address public r33;
    uint256 private __reserved;

    struct ForfeitedReward {
        uint256 period;
        uint256 amount;
    }

    mapping(bytes32 => mapping(address => ForfeitedReward)) public forfeitedRewards;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// @dev to a function before the Gauge is initialized.
    modifier lock() {
        require(_unlocked, Errors.LOCKED());
        _unlocked = false;
        _;
        _unlocked = true;
    }

    /// @dev pushes fees from the pool to fee distributor on notify rewards
    modifier pushFees() {
        feeCollector.collectProtocolFees(address(pool));
        _;
    }
    
    /// @dev Ensures the address is an authorized claimer
    modifier onlyAuthorizedClaimer() {
        require(_isAuthorizedClaimer(msg.sender), Errors.NOT_AUTHORIZED_CLAIMER(msg.sender));
        _;
    }

    /// @dev Allows either voter or authorized claimers
    modifier onlyAuthorizedClaimerOrVoter() {
        require(
            msg.sender == voter || _isAuthorizedClaimer(msg.sender), 
            Errors.NOT_AUTHORIZED(msg.sender)
        );
        _;
    }

    function initialize(
        address _voter,
        address _nfpManager, // legacy for backward compatibility
        address _feeCollector,
        address _pool
    ) public initializer {
        _unlocked = true;

        voter = _voter;
        feeCollector = IFeeCollector(_feeCollector);
        nfpManager = INonfungiblePositionManager(_nfpManager); // legacy for backward compatibility
        pool = IRamsesV3Pool(_pool);
        firstPeriod = _blockTimestamp() / WEEK;
        /// @dev pull from voter
        syncCache();


        address ram = IVoter(_voter).ram();
        address xphar = IVoter(_voter).xRam();

        (address token0, address token1) = (
            IRamsesV3Pool(_pool).token0(),
            IRamsesV3Pool(_pool).token1()
        );

        _addInitialReward(token0);
        _addInitialReward(token1);
        _addInitialReward(xphar);
        _addInitialReward(ram);
    }

    /// @dev skips zero and duplicate tokens (e.g. xRam unset, or a pool token that is also ram/xRam)
    function _addInitialReward(address token) private {
        if (token != address(0) && !isReward[token]) {
            rewards.push(token);
            isReward[token] = true;
            emit RewardAdded(token);
        }
    }


    constructor() {
        _disableInitializers();
    }

    function _blockTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }



    /// @notice Check if an address is an authorized claimer
    function _isAuthorizedClaimer(address claimer) internal view returns (bool) {
        return authorizedClaimers.contains(claimer);
    }

    /// @inheritdoc IGaugeV3
    function isAuthorizedClaimer(address claimer) external view returns (bool) {
        return authorizedClaimers.contains(claimer);
    }

    /// @inheritdoc IGaugeV3
    function getAuthorizedClaimers() external view returns (address[] memory) {
        return authorizedClaimers.values();
    }

    /// @inheritdoc IGaugeV3
    function left(address token) external view override returns (uint256) {
        uint256 period = _blockTimestamp() / WEEK;
        uint256 remainingTime = ((period + 1) * WEEK) - _blockTimestamp();
        return (tokenTotalSupplyByPeriod[period][token] * remainingTime) / WEEK;
    }

    /// @inheritdoc IGaugeV3
    function rewardRate(address token) external view returns (uint256) {
        uint256 period = _blockTimestamp() / WEEK;
        return (tokenTotalSupplyByPeriod[period][token] / WEEK);
    }

    /// @inheritdoc IGaugeV3
    function getRewardTokens() external view override returns (address[] memory) {
        return rewards;
    }

    /// @inheritdoc IGaugeV3
    function positionHash(address owner, uint256 index, int24 tickLower, int24 tickUpper)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, index, tickLower, tickUpper));
    }

    /// @inheritdoc IGaugeV3
    function notifyRewardAmount(
        address token,
        uint256 amount
    ) external override pushFees lock {
        require(amount > 0, Errors.NOT_GT_ZERO(amount));
        require(isReward[token], Errors.NOT_WHITELISTED(token));
        IRamsesV3Pool(pool)._advancePeriod();
        uint256 period = _blockTimestamp() / WEEK;

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        amount = balanceAfter - balanceBefore;
        tokenTotalSupplyByPeriod[period][token] += amount;
        emit NotifyReward(msg.sender, token, amount, period);
    }

    /// @inheritdoc IGaugeV3
    function notifyRewardAmountNextPeriod(address token, uint256 amount) external lock {
        require(amount > 0, Errors.NOT_GT_ZERO(amount));
        require(isReward[token], Errors.NOT_WHITELISTED(token));
        uint256 period = (_blockTimestamp() / WEEK) + 1;
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        amount = balanceAfter - balanceBefore;
        tokenTotalSupplyByPeriod[period][token] += amount;

        emit NotifyReward(msg.sender, token, amount, period);
    }

    /// @inheritdoc IGaugeV3
    function notifyRewardAmountForPeriod(address token, uint256 amount, uint256 period) external lock {
        require(amount > 0, Errors.NOT_GT_ZERO(amount));
        require(isReward[token], Errors.NOT_WHITELISTED(token));
        require(period > _blockTimestamp() / WEEK, Errors.CANT_REWARD_PAST());
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        amount = balanceAfter - balanceBefore;
        tokenTotalSupplyByPeriod[period][token] += amount;

        emit NotifyReward(msg.sender, token, amount, period);
    }

    /// @inheritdoc IGaugeV3
    function earned(address token, uint256 tokenId) external view returns (uint256 reward) {
        INonfungiblePositionManager _nfpManager = nfpManager;
        (,,, int24 tickLower, int24 tickUpper,,,,,) = _nfpManager.positions(tokenId);

        bytes32 _positionHash = positionHash(address(_nfpManager), tokenId, tickLower, tickUpper);

        uint256 lastClaim = Math.max(lastClaimByToken[token][_positionHash], firstPeriod);
        uint256 currentPeriod = _blockTimestamp() / WEEK;
        for (uint256 period = lastClaim; period <= currentPeriod; ++period) {
            reward += periodEarned(period, token, address(_nfpManager), tokenId, tickLower, tickUpper);
        }
    }

    /// @inheritdoc IGaugeV3
    function earned(
        address token, 
        address nfpManagerAddress,
        uint256 tokenId
    ) external view returns (uint256 reward) {
        INonfungiblePositionManager _nfpManager = INonfungiblePositionManager(nfpManagerAddress);
        (,,, int24 tickLower, int24 tickUpper,,,,,) = _nfpManager.positions(tokenId);
        
        bytes32 _positionHash = positionHash(nfpManagerAddress, tokenId, tickLower, tickUpper);
        
        uint256 lastClaim = Math.max(lastClaimByToken[token][_positionHash], firstPeriod);
        uint256 currentPeriod = _blockTimestamp() / WEEK;
        
        for (uint256 period = lastClaim; period <= currentPeriod; ++period) {
            reward += periodEarned(period, token, nfpManagerAddress, tokenId, tickLower, tickUpper);
        }
    }

    /// @inheritdoc IGaugeV3
    function periodEarned(uint256 period, address token, uint256 tokenId) public view override returns (uint256) {
        INonfungiblePositionManager _nfpManager = nfpManager;
        (,,, int24 tickLower, int24 tickUpper,,,,,) = _nfpManager.positions(tokenId);

        return periodEarned(period, token, address(_nfpManager), tokenId, tickLower, tickUpper);
    }

    /// @inheritdoc IGaugeV3
    function periodEarned(uint256 period, address token, address nfpManagerAddress, uint256 tokenId) public view override returns (uint256) {
        INonfungiblePositionManager _nfpManager = INonfungiblePositionManager(nfpManagerAddress);
        (,,, int24 tickLower, int24 tickUpper,,,,,) = _nfpManager.positions(tokenId);

        return periodEarned(period, token, nfpManagerAddress, tokenId, tickLower, tickUpper);
    }

    /// @inheritdoc IGaugeV3
    function periodEarned(uint256 period, address token, address owner, uint256 index, int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint256 amount)
    {
        (bool success, bytes memory data) = address(this).staticcall(
            abi.encodeCall(this.cachePeriodEarned, (period, token, owner, index, tickLower, tickUpper, false))
        );

        if (!success) {
            return 0;
        }

        amount = abi.decode(data, (uint256));
        bytes32 hash = positionHash(owner, index, tickLower, tickUpper);
        return amount - _forfeitedShare(period, token, hash, amount);
    }

    /// @inheritdoc IGaugeV3
    /// @dev used by getReward() and saves gas by saving states
    function cachePeriodEarned(
        uint256 period,
        address token,
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        bool caching
    ) public override returns (uint256 amount) {
        uint256 periodSecondsInsideX96;

        bytes32 _positionHash = positionHash(owner, index, tickLower, tickUpper);

        /// @dev get seconds from pool if not already written into storage
        if (!periodAmountsWritten[period][_positionHash]) {
            (bool success, bytes memory data) = address(pool).staticcall(
                abi.encodeCall(
                    IRamsesV3PoolState.positionPeriodSecondsInRange, (period, owner, index, tickLower, tickUpper)
                )
            );

            if (!success) {
                return 0;
            }

            (periodSecondsInsideX96) = abi.decode(data, (uint256));

            if (period < _blockTimestamp() / WEEK && caching) {
                periodAmountsWritten[period][_positionHash] = true;
                periodNfpSecondsX96[period][_positionHash] = periodSecondsInsideX96;
            }
        } else {
            periodSecondsInsideX96 = periodNfpSecondsX96[period][_positionHash];
        }

        amount = FullMath.mulDiv(tokenTotalSupplyByPeriod[period][token], periodSecondsInsideX96, WEEK << 96);

        uint256 claimed = periodClaimedAmount[period][_positionHash][token];
        if (amount >= claimed) {
            amount -= claimed;
        } else {
            amount = 0;
        }

        return amount;
    }

    /// @inheritdoc IGaugeV3
    function getPeriodReward(
        uint256 period,
        address[] calldata tokens,
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        address receiver
    ) external override lock onlyAuthorizedClaimer {
        require(msg.sender == owner, Errors.NOT_AUTHORIZED(msg.sender));
        
        bytes32 _positionHash = positionHash(owner, index, tickLower, tickUpper);
        pool._advancePeriod();

        for (uint256 i = 0; i < tokens.length; ++i) {
            _getReward(period, tokens[i], owner, index, tickLower, tickUpper, _positionHash, receiver, false);
        }
    }

    /// @inheritdoc IGaugeV3
    function getReward(uint256[] calldata tokenIds, address[] memory tokens) external {
        uint256 length = tokenIds.length;

        for (uint256 i = 0; i < length; ++i) {
            getReward(tokenIds[i], tokens);
        }
    }

    /// @inheritdoc IGaugeV3
    function getReward(uint256 tokenId, address[] memory tokens) public lock onlyAuthorizedClaimer {
        INonfungiblePositionManager _nfpManager = nfpManager;
        
        address owner = _nfpManager.ownerOf(tokenId);
        address operator = _nfpManager.getApproved(tokenId);
        /// @dev check if owner, operator, or approved for all
        require(
            msg.sender == owner || msg.sender == operator || _nfpManager.isApprovedForAll(owner, msg.sender),
            Errors.NOT_AUTHORIZED(msg.sender)
        );

        (,,, int24 tickLower, int24 tickUpper,,,,,) = _nfpManager.positions(tokenId);

        _getAllRewards(address(_nfpManager), tokenId, tickLower, tickUpper, tokens, msg.sender);
    }
    
    /// @inheritdoc IGaugeV3
    function getRewardForOwner(uint256 tokenId, address[] memory tokens) external lock onlyAuthorizedClaimerOrVoter {
        // If voter is calling, use the legacy nfpManager; otherwise use msg.sender
        INonfungiblePositionManager _nfpManager = msg.sender == voter 
            ? nfpManager 
            : INonfungiblePositionManager(msg.sender);
            
        address owner = _nfpManager.ownerOf(tokenId);
        (,,, int24 tickLower, int24 tickUpper,,,,,) = _nfpManager.positions(tokenId);
        
        _getAllRewards(address(_nfpManager), tokenId, tickLower, tickUpper, tokens, owner);
    }

    /// @inheritdoc IGaugeV3
    function getRewardForOwnerFromVoter(
        address nfpManagerAddress,
        uint256 tokenId,
        address[] memory tokens
    ) external lock onlyAuthorizedClaimerOrVoter {
        INonfungiblePositionManager _nfpManager = INonfungiblePositionManager(nfpManagerAddress);
        address owner = _nfpManager.ownerOf(tokenId);
        (,,, int24 tickLower, int24 tickUpper,,,,,) = _nfpManager.positions(tokenId);
        
        _getAllRewards(nfpManagerAddress, tokenId, tickLower, tickUpper, tokens, owner);
    }

    function getReward(
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        address[] memory tokens,
        address receiver
    ) external lock onlyAuthorizedClaimer {
        require(msg.sender == owner, Errors.NOT_AUTHORIZED(msg.sender));
        _getAllRewards(owner, index, tickLower, tickUpper, tokens, receiver);
    }

    function _getAllRewards(
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        address[] memory tokens,
        address receiver
    ) internal {
        bytes32 _positionHash = positionHash(owner, index, tickLower, tickUpper);

        pool._advancePeriod();
        if (_shouldSlash(owner, receiver, _positionHash, index, tickLower, tickUpper)) {
            _recordForfeit(owner, index, tickLower, tickUpper, tokens, _positionHash);
            emit Forfeited(_positionHash, owner, index, tickLower, tickUpper, tx.origin);
            return;
        }

        _claimAll(owner, index, tickLower, tickUpper, tokens, receiver, _positionHash);
    }

    function _recordForfeit(
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        address[] memory tokens,
        bytes32 hash
    ) internal {
        uint256 period = _blockTimestamp() / WEEK;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 unpaid = cachePeriodEarned(period, tokens[i], owner, index, tickLower, tickUpper, false);
            forfeitedRewards[hash][tokens[i]] = ForfeitedReward(period, unpaid);
        }
    }

    function _forfeitedShare(uint256 period, address token, bytes32 hash, uint256 unpaid)
        internal view returns (uint256)
    {
        ForfeitedReward memory debt = forfeitedRewards[hash][token];
        if (debt.period == 0 || period > debt.period) return 0;
        return period < debt.period ? unpaid : Math.min(unpaid, debt.amount);
    }

    function _claimAll(
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        address[] memory tokens,
        address receiver,
        bytes32 _positionHash
    ) internal {
        uint256 currentPeriod = _blockTimestamp() / WEEK;
        uint256 lastClaim;
        for (uint256 i = 0; i < tokens.length; ++i) {
            lastClaim = Math.max(lastClaimByToken[tokens[i]][_positionHash], firstPeriod);
            for (uint256 period = lastClaim; period <= currentPeriod; ++period) {
                _getReward(period, tokens[i], owner, index, tickLower, tickUpper, _positionHash, receiver, false);
            }
            lastClaimByToken[tokens[i]][_positionHash] = currentPeriod;
        }
    }

    function sweepForfeited(
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        address[] calldata tokens
    ) external lock {
        pool._advancePeriod();
        bytes32 _positionHash = positionHash(owner, index, tickLower, tickUpper);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 cutoff = forfeitedRewards[_positionHash][tokens[i]].period;
            uint256 start = Math.max(lastClaimByToken[tokens[i]][_positionHash], firstPeriod);
            for (uint256 period = start; period <= cutoff; ++period) {
                _getReward(period, tokens[i], owner, index, tickLower, tickUpper, _positionHash, address(0), true);
            }
        }
    }

    /// @dev r33 where deployed, else the FeeCollector treasury (chains without r33)
    function _slashRecipient() internal view returns (address recipient) {
        recipient = r33 != address(0) ? r33 : feeCollector.treasury();
        require(recipient != address(0), Errors.INVALID_ADDRESS());
    }

    function _shouldSlash(
        address owner,
        address receiver,
        bytes32 _positionHash,
        uint256 index,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (bool) {
        if (address(rewardValidator) == address(0)) return false;
        // fail-closed: a cheap validator revert must not buy a payout
        try rewardValidator.validateReward(owner, receiver, _positionHash, tx.origin, index, tickLower, tickUpper, address(pool))
        returns (bool slash) {
            return slash;
        } catch {
            return true;
        }
    }

    function _getReward(
        uint256 period,
        address token,
        address owner,
        uint256 index,
        int24 tickLower,
        int24 tickUpper,
        bytes32 hash,
        address receiver,
        bool forfeitedOnly
    ) internal {
        uint256 unpaid = cachePeriodEarned(period, token, owner, index, tickLower, tickUpper, true);
        if (unpaid == 0) return;

        uint256 forfeited = _forfeitedShare(period, token, hash, unpaid);
        if (!forfeitedOnly && _shouldSlash(owner, receiver, hash, index, tickLower, tickUpper)) forfeited = unpaid;
        uint256 paid = forfeitedOnly ? 0 : unpaid - forfeited;
        ForfeitedReward storage debt = forfeitedRewards[hash][token];
        if (period == debt.period) debt.amount -= Math.min(debt.amount, forfeited);
        periodClaimedAmount[period][hash][token] += forfeited + paid;

        if (forfeited != 0) {
            address recipient = _slashRecipient();
            IERC20(token).safeTransfer(recipient, forfeited);
            emit ClaimRewards(period, hash, recipient, token, forfeited);
        }
        if (paid != 0) {
            IERC20(token).safeTransfer(receiver, paid);
            emit ClaimRewards(period, hash, receiver, token, paid);
        }
    }

    function addRewards(address reward) external {
        require(msg.sender == IVoter(voter).accessHub(), Errors.NOT_AUTHORIZED(msg.sender));
        if (!isReward[reward]) {
            rewards.push(reward);
            isReward[reward] = true;
            emit RewardAdded(reward);
        }
    }

    function removeRewards(address reward) external {
        require(msg.sender == IVoter(voter).accessHub(), Errors.NOT_AUTHORIZED(msg.sender));
        if (isReward[reward]) {
            uint256 idx;

            for (uint256 i; i < rewards.length; ++i) {
                if (rewards[i] == reward) {
                    idx = i;
                    break;
                }
            }

            for (uint256 i = idx; i < rewards.length - 1; ++i) {
                rewards[i] = rewards[i + 1];
            }

            rewards.pop();
            isReward[reward] = false;

            emit RewardRemoved(reward);
        }
    }


    
    /// @inheritdoc IGaugeV3
    function syncCache() public {
        // Sync reward validator
        rewardValidator = IRewardValidator(IVoter(voter).rewardValidator());
        
        // Sync r33 cache
        r33 = address(IAccessHub(IVoter(voter).accessHub()).r33());
        
        // Sync feeCollector from AccessHub
        feeCollector = IFeeCollector(IAccessHub(IVoter(voter).accessHub()).feeCollector());
        
        // Sync authorized claimers
        // clear existing
        while (authorizedClaimers.length() > 0) {
            authorizedClaimers.remove(authorizedClaimers.at(0));
        }
        
        // get authorized claimers from voter
        address[] memory claimers = IVoter(voter).getAllAuthorizedClaimers();
        for (uint i = 0; i < claimers.length; i++) {
            authorizedClaimers.add(claimers[i]);
        }
    }
}
