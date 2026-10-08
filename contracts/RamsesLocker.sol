// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonfungiblePositionManager} from "./CL/periphery/interfaces/INonfungiblePositionManager.sol";
import {PoolAddress} from "./CL/periphery/libraries/PoolAddress.sol";
import {IRamsesV3Pool} from "./CL/core/interfaces/IRamsesV3Pool.sol";
import {FullMath} from "./CL/core/libraries/FullMath.sol";
import {FixedPoint128} from "./CL/core/libraries/FixedPoint128.sol";
import {IGaugeV3} from "./CL/gauge/interfaces/IGaugeV3.sol";
import {IVoter} from "./interfaces/IVoter.sol";

/// @notice Locks CL positions forever. Fees and gauge rewards go to each position's receiver.
/// @dev No admin and no unlock. Approve the locker, then call `lock`. NFTs sent here directly are stuck.
contract RamsesLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public immutable positionManager;
    IVoter public immutable voter;
    address public immutable poolDeployer;

    mapping(uint256 tokenId => address receiver) public feeReceiverOf;
    mapping(uint256 tokenId => address pool) public poolOf;

    event PositionLocked(uint256 indexed tokenId, address indexed pool, address indexed feeReceiver);
    event FeeReceiverUpdated(uint256 indexed tokenId, address indexed oldReceiver, address indexed newReceiver);
    event FeesCollected(
        uint256 indexed tokenId, address indexed feeReceiver, address caller, uint256 amount0, uint256 amount1
    );
    event RewardCollected(
        uint256 indexed tokenId,
        address indexed rewardToken,
        address indexed feeReceiver,
        address caller,
        uint256 amount
    );

    error NotAuthorized();
    error NotLocked();
    error InvalidReceiver();

    modifier onlyOwnerOrApproved(uint256 tokenId) {
        address owner = positionManager.ownerOf(tokenId);
        require(
            msg.sender == owner || msg.sender == positionManager.getApproved(tokenId)
                || positionManager.isApprovedForAll(owner, msg.sender),
            NotAuthorized()
        );
        _;
    }

    modifier onlyFeeReceiver(uint256 tokenId) {
        require(msg.sender == feeReceiverOf[tokenId], NotAuthorized());
        _;
    }

    modifier whenLocked(uint256 tokenId) {
        require(isLocked(tokenId), NotLocked());
        _;
    }

    constructor(address _positionManager, address _voter) {
        positionManager = INonfungiblePositionManager(_positionManager);
        voter = IVoter(_voter);
        poolDeployer = positionManager.deployer();
    }

    // locks it forever, fees already earned come with it
    // once locked the locker owns the nft so nobody passes onlyOwnerOrApproved again
    function lock(uint256 tokenId, address receiver) external onlyOwnerOrApproved(tokenId) {
        require(receiver != address(0), InvalidReceiver());
        (address token0, address token1, int24 tickSpacing,,,,,,,) = positionManager.positions(tokenId);
        address pool = PoolAddress.computeAddress(poolDeployer, PoolAddress.PoolKey(token0, token1, tickSpacing));

        positionManager.transferFrom(positionManager.ownerOf(tokenId), address(this), tokenId);
        feeReceiverOf[tokenId] = receiver;
        poolOf[tokenId] = pool;
        emit PositionLocked(tokenId, pool, receiver);
    }

    // new receiver gets everything not collected yet
    function setFeeReceiver(uint256 tokenId, address newFeeReceiver) external nonReentrant onlyFeeReceiver(tokenId) {
        require(newFeeReceiver != address(0), InvalidReceiver());
        feeReceiverOf[tokenId] = newFeeReceiver;
        emit FeeReceiverUpdated(tokenId, msg.sender, newFeeReceiver);
    }

    // anyone can call, fees always go to the receiver
    function collect(uint256 tokenId)
        external
        nonReentrant
        whenLocked(tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        address receiver = feeReceiverOf[tokenId];
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: receiver, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        emit FeesCollected(tokenId, receiver, msg.sender, amount0, amount1);
    }

    // anyone can call, rewards always go to the receiver
    // claim often, the gauge loops every unclaimed week so gas grows over time
    function collectRewards(uint256 tokenId, address[] calldata tokens)
        external
        nonReentrant
        whenLocked(tokenId)
        returns (uint256[] memory amounts)
    {
        address receiver = feeReceiverOf[tokenId];
        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            before[i] = IERC20(tokens[i]).balanceOf(address(this));
        }

        address[] memory gauges = new address[](1);
        address[][] memory rewardTokens = new address[][](1);
        uint256[][] memory tokenIds = new uint256[][](1);
        address[] memory managers = new address[](1);
        gauges[0] = voter.gaugeForPool(poolOf[tokenId]);
        rewardTokens[0] = tokens;
        tokenIds[0] = new uint256[](1);
        tokenIds[0][0] = tokenId;
        managers[0] = address(positionManager);
        voter.claimClGaugeRewards(gauges, rewardTokens, tokenIds, managers);

        // only forward what this claim paid, stray tokens stay put
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = IERC20(tokens[i]).balanceOf(address(this)) - before[i];
            if (amounts[i] == 0) continue;
            IERC20(tokens[i]).safeTransfer(receiver, amounts[i]);
            emit RewardCollected(tokenId, tokens[i], receiver, msg.sender, amounts[i]);
        }
    }

    function isLocked(uint256 tokenId) public view returns (bool) {
        return feeReceiverOf[tokenId] != address(0);
    }

    // includes fees not checkpointed yet, real collect can be a few wei lower
    function pendingFees(uint256 tokenId) external view returns (uint256 amount0, uint256 amount1) {
        (,,, int24 lower, int24 upper, uint128 liquidity, uint256 last0, uint256 last1, uint128 owed0, uint128 owed1) =
            positionManager.positions(tokenId);
        (uint256 inside0, uint256 inside1) = _feeGrowthInside(IRamsesV3Pool(poolOf[tokenId]), lower, upper);
        unchecked {
            owed0 += uint128(FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128));
            owed1 += uint128(FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128));
        }
        return (owed0, owed1);
    }

    // reverts if the pool has no gauge
    function pendingGaugeRewards(uint256 tokenId, address[] calldata tokens)
        external
        view
        returns (uint256[] memory amounts)
    {
        IGaugeV3 gauge = IGaugeV3(voter.gaugeForPool(poolOf[tokenId]));
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = gauge.earned(tokens[i], address(positionManager), tokenId);
        }
    }

    // same math as Tick.getFeeGrowthInside but read from outside the pool
    // counters wrap on purpose, PositionValue uses checked math so it would revert
    function _feeGrowthInside(IRamsesV3Pool pool, int24 lower, int24 upper)
        private
        view
        returns (uint256 inside0, uint256 inside1)
    {
        (, int24 tick,,,,,) = pool.slot0();
        (,, uint256 lower0, uint256 lower1,,,,) = pool.ticks(lower);
        (,, uint256 upper0, uint256 upper1,,,,) = pool.ticks(upper);
        unchecked {
            if (tick < lower) return (lower0 - upper0, lower1 - upper1);
            if (tick >= upper) return (upper0 - lower0, upper1 - lower1);
            return (pool.feeGrowthGlobal0X128() - lower0 - upper0, pool.feeGrowthGlobal1X128() - lower1 - upper1);
        }
    }
}