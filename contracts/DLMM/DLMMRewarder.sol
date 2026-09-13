// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DLMMBaseHooks} from "./DLMMBaseHooks.sol";
import {IDLMMPool} from "./interfaces/IDLMMPool.sol";
import {Hooks} from "./libraries/Hooks.sol";
import {BinHelper} from "./libraries/BinHelper.sol";
import {PriceHelper} from "./libraries/PriceHelper.sol";
import {SafeCast} from "./libraries/math/SafeCast.sol";
import {Uint256x256Math} from "./libraries/math/Uint256x256Math.sol";

interface IDLMMVoterAntiJit {
    function isAntiSybilEnabled() external view returns (bool);
    function timeThresholdForRewarder() external view returns (uint256);
    function isAuthorizedDLMMManager(address manager) external view returns (bool);
}

contract DLMMRewarder is DLMMBaseHooks, Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Uint256x256Math for uint256;

    event NotifyReward(address indexed from, address indexed reward, uint256 amount);
    event ClaimRewards(address indexed from, address indexed reward, uint256 amount);
    event BinRewardAccumulatorsUpdated(uint24 startBinId, uint256[] accRewardsPerShareX64);

    uint8 internal constant OFFSET_PRECISION = 128;
    int256 internal constant MAX_NUMBER_OF_BINS = 11;
    bytes32 public constant FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_MINT_FLAG | Hooks.BEFORE_BURN_FLAG | Hooks.BEFORE_TRANSFER_FLAG;

    IDLMMPool internal dlmmPool;
    IERC20 internal rewardToken;

    int24 internal deltaBinA;
    int24 internal deltaBinB;
    uint256 internal totalUnclaimedRewards;
    uint256 internal rewardsPerSecond;
    uint256 internal endTimestamp;
    uint256 internal lastUpdateTimestamp;

    struct Bin {
        uint256 accRewardsPerShareX64;
        mapping(address user => uint256 accRewardsPerShareX64) userAccRewardsPerShareX64;
        mapping(address user => uint32 lastModified) userLastModified;
    }

    mapping(uint256 id => Bin bin) internal bins;
    mapping(address user => uint256 rewards) internal unclaimedRewards;

    constructor() {
        _disableInitializers();
    }

    function initialize(IDLMMPool _dlmmPool, IERC20 _rewardToken, address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        dlmmPool = _dlmmPool;
        rewardToken = _rewardToken;
    }

    function getRewardToken() external view returns (address) {
        return address(rewardToken);
    }

    function getHooksParameters() external view returns (bytes32) {
        return Hooks.setHooks(FLAGS, address(this));
    }

    function getRewarderParameter() external view returns (uint256 rewardPerSecond, uint256 lastUpdate, uint256 end) {
        return (rewardsPerSecond, lastUpdateTimestamp, endTimestamp);
    }

    function getRewardedRange() external view returns (uint256 binStart, uint256 binEnd) {
        (,, binStart, binEnd) = _getRewardedRange();
    }

    function getLastModified(address user, uint256 id) external view returns (uint32) {
        return bins[id].userLastModified[user];
    }

    function getRemainingRewards() external view returns (uint256) {
        return rewardToken.balanceOf(address(this)) - totalUnclaimedRewards - _getPendingTotalRewards();
    }

    function getPendingRewards(address user, uint256[] calldata ids) external view returns (uint256 pendingRewards) {
        if (!_isLinked()) return 0;

        IDLMMPool pair = dlmmPool;
        (uint256[] memory rewardedIds, uint24 activeId, uint256 binStart, uint256 binEnd) = _getRewardedRange();
        (uint256[] memory liquiditiesX128, uint256[] memory totalSuppliesX64, uint256 totalLiquiditiesX128) =
            _getLiquidityData(pair, activeId, rewardedIds);
        uint256 pendingTotalRewards = _getPendingTotalRewards();

        for (uint256 i; i < ids.length; ++i) {
            uint24 id = ids[i].safe24();
            uint256 index;
            bool rewarded = id >= binStart && id < binEnd;
            if (rewarded) index = id - binStart;

            pendingRewards += _pendingRewardForId(
                pair,
                user,
                id,
                pendingTotalRewards,
                rewarded && totalLiquiditiesX128 > 0 ? liquiditiesX128[index] : 0,
                rewarded ? totalSuppliesX64[index] : 0,
                totalLiquiditiesX128
            );
        }

        pendingRewards += unclaimedRewards[user];
    }

    function claim(address user, uint256[] calldata ids) external {
        require(user == msg.sender, "unauthorized");
        require(_isLinked(), "unlinked");

        _updateAccruedRewardsPerShare();
        _updateUser(user, _copyIds(ids));

        uint256 rewards = unclaimedRewards[user];
        if (rewards == 0) return;

        totalUnclaimedRewards -= rewards;
        unclaimedRewards[user] = 0;
        rewardToken.safeTransfer(user, rewards);

        emit ClaimRewards(user, address(rewardToken), rewards);
    }

    function setDeltaBins(int24 _deltaBinA, int24 _deltaBinB) external onlyOwner {
        require(_deltaBinA <= _deltaBinB, "invalid delta");
        require(int256(_deltaBinB) - _deltaBinA <= MAX_NUMBER_OF_BINS, "too many bins");
        require(_isRewardedRangeValid(_deltaBinA, _deltaBinB), "range overflow");

        if (_isRewardedRangeValid(deltaBinA, deltaBinB)) {
            _updateAccruedRewardsPerShare();
        } else {
            _updateRewards();
        }

        deltaBinA = _deltaBinA;
        deltaBinB = _deltaBinB;
    }

    function setRewardPerSecond(uint256 maxRewardPerSecond, uint256 expectedDuration)
        external
        onlyOwner
        returns (uint256 rewardPerSecond)
    {
        uint256 startTimestamp = lastUpdateTimestamp > block.timestamp ? lastUpdateTimestamp : block.timestamp;
        return _setRewardParameters(maxRewardPerSecond, startTimestamp, expectedDuration);
    }

    function sweep(IERC20 token, address to) external onlyOwner {
        require(!_isLinked() || token != rewardToken, "locked reward token");
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    function _getLBPair() internal view override returns (IDLMMPool) {
        return dlmmPool;
    }

    function _onHooksSet(bytes32 hooksParameters, bytes calldata) internal view override {
        require(hooksParameters == Hooks.setHooks(FLAGS, address(this)), "invalid hooks");
    }

    function _beforeSwap(address, address, bool, bytes32) internal override {
        _updateAccruedRewardsPerShare();
    }

    function _beforeMint(address sender, address to, bytes32[] calldata liquidityConfigs, bytes32) internal override {
        _checkMintRecipient(sender, to);
        _updateAccruedRewardsPerShare();
        uint256[] memory ids = _convertLiquidityConfigs(liquidityConfigs);
        _updateUser(to, ids);
        _markModified(to, ids);
    }

    function _beforeBurn(address, address from, address, uint256[] calldata ids, uint256[] calldata) internal override {
        _updateAccruedRewardsPerShare();
        uint256[] memory copiedIds = _copyIds(ids);
        _updateUser(from, copiedIds);
        _markModified(from, copiedIds);
    }

    function _beforeBatchTransferFrom(address, address from, address to, uint256[] calldata ids, uint256[] calldata)
        internal
        pure
        override
    {
        if (from != address(0) || to != address(0) || ids.length != 0) revert("transfers disabled");
    }

    function _checkMintRecipient(address sender, address to) internal view {
        if (sender == to) return;

        require(IDLMMVoterAntiJit(owner()).isAuthorizedDLMMManager(sender), "unauthorized manager");
    }

    function _markModified(address user, uint256[] memory ids) internal {
        uint32 timestamp = uint32(block.timestamp);

        for (uint256 i; i < ids.length; ++i) {
            bins[ids[i].safe24()].userLastModified[user] = timestamp;
        }
    }

    function _shouldForfeit(address user, uint24 id) internal view returns (bool) {
        IDLMMVoterAntiJit voter = IDLMMVoterAntiJit(owner());
        if (!voter.isAntiSybilEnabled()) return false;

        uint32 lastModified = bins[id].userLastModified[user];
        if (lastModified == 0) return false;

        return block.timestamp - lastModified <= voter.timeThresholdForRewarder();
    }

    function _releaseRewards(uint256 rewards) internal {
        if (rewards > 0) totalUnclaimedRewards -= rewards;
    }

    function _setRewardParameters(uint256 maxRewardPerSecond, uint256 startTimestamp, uint256 expectedDuration)
        internal
        returns (uint256 rewardPerSecond)
    {
        require(startTimestamp >= block.timestamp, "invalid start");
        require(_isLinked(), "stopped");
        require((expectedDuration == 0) == (maxRewardPerSecond == 0), "invalid duration");

        _updateAccruedRewardsPerShare();

        uint256 remainingReward = rewardToken.balanceOf(address(this)) - totalUnclaimedRewards;
        uint256 maxExpectedReward = maxRewardPerSecond * expectedDuration;

        rewardPerSecond = maxExpectedReward > remainingReward ? remainingReward / expectedDuration : maxRewardPerSecond;
        uint256 expectedReward = rewardPerSecond * expectedDuration;

        require(expectedDuration == 0 || expectedReward != 0, "zero reward");

        rewardsPerSecond = rewardPerSecond;
        endTimestamp = startTimestamp + expectedDuration;
        lastUpdateTimestamp = startTimestamp;

        if (expectedReward != 0) emit NotifyReward(msg.sender, address(rewardToken), expectedReward);
    }

    function _pendingRewardForId(
        IDLMMPool pair,
        address user,
        uint24 id,
        uint256 pendingTotalRewards,
        uint256 liquidityX128,
        uint256 totalSupplyX64,
        uint256 totalLiquiditiesX128
    ) internal view returns (uint256 pendingRewards) {
        Bin storage bin = bins[id];
        uint256 accRewardsPerShareX64 = bin.accRewardsPerShareX64;

        if (totalSupplyX64 > 0 && totalLiquiditiesX128 > 0) {
            uint256 weightX128 = liquidityX128.shiftDivRoundDown(OFFSET_PRECISION, totalLiquiditiesX128);
            accRewardsPerShareX64 += pendingTotalRewards.mulDivRoundDown(weightX128, totalSupplyX64);
        }

        uint256 userAccRewardsPerShareX64 = bin.userAccRewardsPerShareX64[user];
        if (accRewardsPerShareX64 > userAccRewardsPerShareX64) {
            if (_shouldForfeit(user, id)) return 0;

            uint256 rewardsDelta = accRewardsPerShareX64 - userAccRewardsPerShareX64;
            pendingRewards = rewardsDelta.mulShiftRoundDown(pair.balanceOf(user, id), OFFSET_PRECISION);
        }
    }

    function _getRewardedRange()
        internal
        view
        returns (uint256[] memory rewardedIds, uint24 activeId, uint256 binStart, uint256 binEnd)
    {
        activeId = dlmmPool.getActiveId();

        int256 start = int256(uint256(activeId)) + deltaBinA;
        int256 end = int256(uint256(activeId)) + deltaBinB;
        require(start >= 0 && end >= 0 && start <= int256(uint256(type(uint24).max)), "range overflow");
        require(end <= int256(uint256(type(uint24).max)), "range overflow");

        binStart = uint256(start);
        binEnd = uint256(end);
        rewardedIds = new uint256[](binEnd - binStart);

        for (uint256 i; i < rewardedIds.length; ++i) {
            rewardedIds[i] = binStart + i;
        }
    }

    function _isRewardedRangeValid(int24 _deltaBinA, int24 _deltaBinB) internal view returns (bool) {
        uint24 activeId = dlmmPool.getActiveId();

        int256 start = int256(uint256(activeId)) + _deltaBinA;
        int256 end = int256(uint256(activeId)) + _deltaBinB;

        return start >= 0 && end >= 0 && start <= int256(uint256(type(uint24).max))
            && end <= int256(uint256(type(uint24).max));
    }

    function _getLiquidityData(IDLMMPool pair, uint24 activeId, uint256[] memory ids)
        internal
        view
        returns (uint256[] memory liquiditiesX128, uint256[] memory totalSuppliesX64, uint256 totalLiquiditiesX128)
    {
        uint256 activePriceX128 = PriceHelper.getPriceFromId(activeId, pair.getBinStep());
        liquiditiesX128 = new uint256[](ids.length);
        totalSuppliesX64 = new uint256[](ids.length);

        for (uint256 i; i < ids.length; ++i) {
            uint24 id = ids[i].safe24();
            (uint128 binReserveX, uint128 binReserveY) = pair.getBin(id);

            uint256 liquidityX128 = BinHelper.getLiquidity(binReserveX, binReserveY, activePriceX128);

            liquiditiesX128[i] = liquidityX128;
            totalSuppliesX64[i] = pair.totalSupply(id);
            totalLiquiditiesX128 += liquidityX128;
        }
    }

    function _updateAccruedRewardsPerShare() internal {
        uint256 pendingTotalRewards = _updateRewards();
        if (pendingTotalRewards == 0) return;

        IDLMMPool pair = dlmmPool;
        (uint256[] memory ids, uint24 activeId,,) = _getRewardedRange();
        (uint256[] memory liquiditiesX128, uint256[] memory totalSuppliesX64, uint256 totalLiquiditiesX128) =
            _getLiquidityData(pair, activeId, ids);

        if (totalLiquiditiesX128 == 0) return;

        totalUnclaimedRewards += pendingTotalRewards;

        uint256[] memory accRewardsPerShareX64 = new uint256[](ids.length);
        bool updated;

        for (uint256 i; i < ids.length; ++i) {
            uint256 totalSupplyX64 = totalSuppliesX64[i];
            uint24 id = ids[i].safe24();
            if (totalSupplyX64 > 0) {
                uint256 weightX128 = liquiditiesX128[i].shiftDivRoundDown(OFFSET_PRECISION, totalLiquiditiesX128);
                uint256 accRewardsDeltaX64 = pendingTotalRewards.mulDivRoundDown(weightX128, totalSupplyX64);
                if (accRewardsDeltaX64 > 0) {
                    bins[id].accRewardsPerShareX64 += accRewardsDeltaX64;
                    updated = true;
                }
            }

            accRewardsPerShareX64[i] = bins[id].accRewardsPerShareX64;
        }

        if (updated) emit BinRewardAccumulatorsUpdated(ids[0].safe24(), accRewardsPerShareX64);
    }

    function _updateUser(address user, uint256[] memory ids) internal {
        IDLMMPool pair = dlmmPool;
        uint256 pendingRewards;
        uint256 forfeitedRewards;

        for (uint256 i; i < ids.length; ++i) {
            uint24 id = ids[i].safe24();
            Bin storage bin = bins[id];

            uint256 accRewardsPerShareX64 = bin.accRewardsPerShareX64;
            uint256 userAccRewardsPerShareX64 = bin.userAccRewardsPerShareX64[user];

            if (accRewardsPerShareX64 > userAccRewardsPerShareX64) {
                uint256 rewardsDelta = accRewardsPerShareX64 - userAccRewardsPerShareX64;
                uint256 userRewards = rewardsDelta.mulShiftRoundDown(pair.balanceOf(user, id), OFFSET_PRECISION);

                bin.userAccRewardsPerShareX64[user] = accRewardsPerShareX64;

                if (_shouldForfeit(user, id)) {
                    forfeitedRewards += userRewards;
                } else {
                    pendingRewards += userRewards;
                }
            }
        }

        if (forfeitedRewards > 0) _releaseRewards(forfeitedRewards);
        if (pendingRewards > 0) unclaimedRewards[user] += pendingRewards;
    }

    function _getPendingTotalRewards() internal view returns (uint256 pendingTotalRewards) {
        uint256 lastUpdate = lastUpdateTimestamp;

        if (block.timestamp > lastUpdate) {
            uint256 end = endTimestamp;
            if (end <= lastUpdate) return 0;

            uint256 deltaTimestamp = block.timestamp < end ? block.timestamp - lastUpdate : end - lastUpdate;
            pendingTotalRewards = rewardsPerSecond * deltaTimestamp;
        }
    }

    function _updateRewards() internal returns (uint256 pendingTotalRewards) {
        pendingTotalRewards = _getPendingTotalRewards();
        if (block.timestamp > lastUpdateTimestamp) lastUpdateTimestamp = block.timestamp;
    }

    function _convertLiquidityConfigs(bytes32[] calldata liquidityConfigs)
        internal
        pure
        returns (uint256[] memory ids)
    {
        ids = new uint256[](liquidityConfigs.length);

        for (uint256 i; i < liquidityConfigs.length; ++i) {
            ids[i] = uint24(uint256(liquidityConfigs[i]));
        }
    }

    function _copyIds(uint256[] calldata ids) internal pure returns (uint256[] memory copiedIds) {
        copiedIds = new uint256[](ids.length);

        for (uint256 i; i < ids.length; ++i) {
            copiedIds[i] = ids[i];
        }
    }
}
