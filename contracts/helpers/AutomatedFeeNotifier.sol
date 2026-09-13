// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFeeCollector} from "../CL/gauge/interfaces/IFeeCollector.sol";
import {IRamsesV3Pool} from "../CL/core/interfaces/IRamsesV3Pool.sol";
import {IDLMMFeeCollector} from "../DLMM/interfaces/IDLMMFeeCollector.sol";
import {IDLMMPool} from "../DLMM/interfaces/IDLMMPool.sol";
import {IDLMMFactory} from "../DLMM/interfaces/IDLMMFactory.sol";
import {IVoter} from "../interfaces/IVoter.sol";

interface ILegacyPool {
    function mintFee() external;
    function feeRecipient() external view returns (address);
    function balanceOf(address) external view returns (uint256);
}

interface IFactory {
    function isPair(address) external view returns (bool);
    function isPairV3(address) external view returns (bool);
}

interface IFeeNotifier {
    function notifyFees() external;
}

/// @title FeeNotifier
/// @notice Automates protocol fee collection for legacy, CL, and DLMM pools
/// @dev Batch processes fees to minimize gas costs
contract AutomatedFeeNotifier {
    /// @notice The fee collector contract for V3 pools
    IFeeCollector public immutable COLLECTOR;

    /// @notice Factory contract for legacy V2 pools
    IFactory public immutable LEGACY_FACTORY;

    /// @notice Factory contract for V3 pools
    IFactory public immutable V3_FACTORY;

    /// @notice Factory contract for DLMM pools
    IDLMMFactory public immutable DLMM_FACTORY;

    /// @notice Voter contract
    IVoter public immutable VOTER;

    /// @notice Minimum fee threshold to trigger collection (avoids dust)
    uint128 public constant MIN_FEE_THRESHOLD = 1;

    error InvalidAddress();
    error NoFeesToCollect();

    event V3FeeCollectionFailed(address indexed pool, bytes reason);

    constructor(
        address _collector,
        address _legacyFactory,
        address _v3Factory,
        address _voter,
        address _dlmmFactory
    ) {
        if (_collector == address(0) || _legacyFactory == address(0) || _v3Factory == address(0)) {
            revert InvalidAddress();
        }

        COLLECTOR = IFeeCollector(_collector);
        LEGACY_FACTORY = IFactory(_legacyFactory);
        V3_FACTORY = IFactory(_v3Factory);
        DLMM_FACTORY = IDLMMFactory(_dlmmFactory);
        VOTER = IVoter(_voter);
    }

    /// @notice Processes protocol fees for specified pools
    /// @param _pools Array of pool addresses to collect fees from
    function notify(IRamsesV3Pool[] calldata _pools) external {
        uint256 poolsLength = _pools.length;

        for (uint256 i; i < poolsLength;) {
            address poolAddress = address(_pools[i]);

            if (_isDLMMPool(poolAddress)) {
                _processDLMMPool(poolAddress);
            } else if (V3_FACTORY.isPairV3(poolAddress)) {
                _processV3Pool(poolAddress);
            } else if (LEGACY_FACTORY.isPair(poolAddress)) {
                _processLegacyPool(poolAddress);
            }

            unchecked { ++i; }
        }
    }

    /// @notice Processes V3 pool fees
    /// @param poolAddress Address of the V3 pool
    function _processV3Pool(address poolAddress) private {
        (uint128 amount0, uint128 amount1) = IRamsesV3Pool(poolAddress).protocolFees();

        if (amount0 > MIN_FEE_THRESHOLD || amount1 > MIN_FEE_THRESHOLD) {
            try COLLECTOR.collectProtocolFees(poolAddress) {}
            catch (bytes memory reason) {
                emit V3FeeCollectionFailed(poolAddress, reason);
            }
        }
    }

    /// @notice Processes DLMM pool fees
    /// @param poolAddress Address of the DLMM pool
    function _processDLMMPool(address poolAddress) private {
        (uint128 amountX, uint128 amountY) = IDLMMPool(poolAddress).getProtocolFees();

        if (amountX > MIN_FEE_THRESHOLD || amountY > MIN_FEE_THRESHOLD) {
            address feeCollector = DLMM_FACTORY.feeCollector();
            if (feeCollector != address(0)) IDLMMFeeCollector(feeCollector).collectProtocolFees(poolAddress);
        }
    }

    /// @notice Processes legacy pool fees
    /// @param poolAddress Address of the legacy pool
    function _processLegacyPool(address poolAddress) private {
        ILegacyPool pool = ILegacyPool(poolAddress);
        pool.mintFee();

        address feeRecipient = pool.feeRecipient();
        address gauge = VOTER.gaugeForPool(poolAddress);

        if (feeRecipient != address(0) && VOTER.isAlive(gauge)) {
            IFeeNotifier(feeRecipient).notifyFees();
        }
    }

    /// @notice Returns pending protocol fees for a V3 pool
    /// @param _pool Address of the V3 pool to check
    /// @return poolAddress Address of the V3 pool
    /// @return tokens Array of token addresses [token0, token1]
    /// @return amounts Array of pending fee amounts [amount0, amount1]
    function getPendingV3Fees(address _pool)
        external
        view
        returns (address poolAddress, address[] memory tokens, uint128[] memory amounts)
    {
        poolAddress = _pool;
        IRamsesV3Pool pool = IRamsesV3Pool(_pool);

        tokens = new address[](2);
        amounts = new uint128[](2);

        tokens[0] = pool.token0();
        tokens[1] = pool.token1();
        (amounts[0], amounts[1]) = pool.protocolFees();

    }

    /// @notice Returns pending protocol fees for a DLMM pool
    /// @param _pool Address of the DLMM pool to check
    /// @return poolAddress Address of the DLMM pool
    /// @return tokens Array of token addresses [tokenX, tokenY]
    /// @return amounts Array of pending fee amounts [amountX, amountY]
    function getPendingDLMMFees(address _pool)
        external
        view
        returns (address poolAddress, address[] memory tokens, uint128[] memory amounts)
    {
        poolAddress = _pool;
        IDLMMPool pool = IDLMMPool(_pool);

        tokens = new address[](2);
        amounts = new uint128[](2);

        tokens[0] = address(pool.getTokenX());
        tokens[1] = address(pool.getTokenY());
        (amounts[0], amounts[1]) = pool.getProtocolFees();
    }

    /// @notice Checks if a legacy pool has pending LP fees to collect
    /// @param _pair Address of the legacy pair to check
    /// @return True if there are pending LP tokens to be minted
    function hasPendingLegacyFees(address _pair) external view returns (bool) {
        if (!LEGACY_FACTORY.isPair(_pair)) return false;

        ILegacyPool pool = ILegacyPool(_pair);
        address feeRecipient = pool.feeRecipient();


        return feeRecipient != address(0) && pool.balanceOf(feeRecipient) > MIN_FEE_THRESHOLD;
    }

    function _isDLMMPool(address poolAddress) private view returns (bool) {
        IDLMMFactory dlmmFactory = DLMM_FACTORY;

        return address(dlmmFactory) != address(0) && dlmmFactory.isPool(poolAddress);
    }
}
