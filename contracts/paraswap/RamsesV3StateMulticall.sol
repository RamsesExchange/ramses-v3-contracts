// SPDX-License-Identifier: ISC
pragma solidity ^0.8.26;

import {IRamsesV3Factory} from "../CL/core/interfaces/IRamsesV3Factory.sol";
import {IRamsesV3Pool} from "../CL/core/interfaces/IRamsesV3Pool.sol";

/// @title RamsesV3StateMulticall
/// @notice ParaSwap-compatible batch state reader for RamsesV3 pools.
///         Reads slot0, liquidity, ticks, tickBitmap, and observations in a single call.
///         Adapted from UniswapV3StateMulticall: factory.getPool uses int24 tickSpacing
///         instead of uint24 fee.
contract RamsesV3StateMulticall {

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint24 feeProtocol;
        bool unlocked;
    }

    struct TickBitMapMappings {
        int16 index;
        uint256 value;
    }

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        int56 tickCumulativeOutside;
        uint160 secondsPerLiquidityOutsideX128;
        uint32 secondsOutside;
        bool initialized;
    }

    struct TickInfoMappings {
        int24 index;
        TickInfo value;
    }

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    struct StateResult {
        IRamsesV3Pool pool;
        uint256 blockTimestamp;
        Slot0 slot0;
        uint128 liquidity;
        int24 tickSpacing;
        uint128 maxLiquidityPerTick;
        Observation observation;
        TickBitMapMappings[] tickBitmap;
        TickInfoMappings[] ticks;
    }

    function getFullState(
        IRamsesV3Factory factory, address tokenIn, address tokenOut,
        int24 tickSpacing, int16 tickBitmapStart, int16 tickBitmapEnd
    ) external view returns (StateResult memory state) {
        require(tickBitmapEnd >= tickBitmapStart, "tickBitmapEnd < tickBitmapStart");
        state = _fillStateWithoutTicks(factory, tokenIn, tokenOut, tickSpacing, tickBitmapStart, tickBitmapEnd);
        state.ticks = _calcTicksFromBitMap(state.pool, state.tickBitmap);
    }

    function getFullStateWithoutTicks(
        IRamsesV3Factory factory, address tokenIn, address tokenOut,
        int24 tickSpacing, int16 tickBitmapStart, int16 tickBitmapEnd
    ) external view returns (StateResult memory state) {
        require(tickBitmapEnd >= tickBitmapStart, "tickBitmapEnd < tickBitmapStart");
        return _fillStateWithoutTicks(factory, tokenIn, tokenOut, tickSpacing, tickBitmapStart, tickBitmapEnd);
    }

    function getFullStateWithRelativeBitmaps(
        IRamsesV3Factory factory, address tokenIn, address tokenOut,
        int24 tickSpacing, int16 leftBitmapAmount, int16 rightBitmapAmount
    ) external view returns (StateResult memory state) {
        require(leftBitmapAmount > 0, "leftBitmapAmount <= 0");
        require(rightBitmapAmount > 0, "rightBitmapAmount <= 0");

        state = _fillStateWithoutBitmapsAndTicks(factory, tokenIn, tokenOut, tickSpacing);
        int16 currentBitmapIndex = _getBitmapIndexFromTick(state.slot0.tick / state.tickSpacing);

        state.tickBitmap = _calcTickBitmaps(
            state.pool,
            currentBitmapIndex - leftBitmapAmount,
            currentBitmapIndex + rightBitmapAmount
        );
        state.ticks = _calcTicksFromBitMap(state.pool, state.tickBitmap);
    }

    function getAdditionalBitmapWithTicks(
        IRamsesV3Factory factory, address tokenIn, address tokenOut,
        int24 tickSpacing, int16 tickBitmapStart, int16 tickBitmapEnd
    ) external view returns (TickBitMapMappings[] memory tickBitmap, TickInfoMappings[] memory ticks) {
        require(tickBitmapEnd >= tickBitmapStart, "tickBitmapEnd < tickBitmapStart");
        IRamsesV3Pool pool = _getPool(factory, tokenIn, tokenOut, tickSpacing);
        tickBitmap = _calcTickBitmaps(pool, tickBitmapStart, tickBitmapEnd);
        ticks = _calcTicksFromBitMap(pool, tickBitmap);
    }

    function getAdditionalBitmapWithoutTicks(
        IRamsesV3Factory factory, address tokenIn, address tokenOut,
        int24 tickSpacing, int16 tickBitmapStart, int16 tickBitmapEnd
    ) external view returns (TickBitMapMappings[] memory tickBitmap) {
        require(tickBitmapEnd >= tickBitmapStart, "tickBitmapEnd < tickBitmapStart");
        IRamsesV3Pool pool = _getPool(factory, tokenIn, tokenOut, tickSpacing);
        return _calcTickBitmaps(pool, tickBitmapStart, tickBitmapEnd);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    function _fillStateWithoutTicks(
        IRamsesV3Factory factory, address tokenIn, address tokenOut,
        int24 tickSpacing, int16 tickBitmapStart, int16 tickBitmapEnd
    ) internal view returns (StateResult memory state) {
        state = _fillStateWithoutBitmapsAndTicks(factory, tokenIn, tokenOut, tickSpacing);
        state.tickBitmap = _calcTickBitmaps(state.pool, tickBitmapStart, tickBitmapEnd);
    }

    function _fillStateWithoutBitmapsAndTicks(
        IRamsesV3Factory factory, address tokenIn, address tokenOut, int24 tickSpacing
    ) internal view returns (StateResult memory state) {
        IRamsesV3Pool pool = _getPool(factory, tokenIn, tokenOut, tickSpacing);

        state.pool = pool;
        state.blockTimestamp = block.timestamp;
        state.liquidity = pool.liquidity();
        state.tickSpacing = pool.tickSpacing();
        state.maxLiquidityPerTick = pool.maxLiquidityPerTick();

        (
            state.slot0.sqrtPriceX96, state.slot0.tick,
            state.slot0.observationIndex, state.slot0.observationCardinality,
            state.slot0.observationCardinalityNext, state.slot0.feeProtocol,
            state.slot0.unlocked
        ) = pool.slot0();

        (
            state.observation.blockTimestamp, state.observation.tickCumulative,
            state.observation.secondsPerLiquidityCumulativeX128, state.observation.initialized
        ) = pool.observations(state.slot0.observationIndex);
    }

    function _calcTickBitmaps(
        IRamsesV3Pool pool, int16 tickBitmapStart, int16 tickBitmapEnd
    ) internal view returns (TickBitMapMappings[] memory tickBitmap) {
        uint256 numberOfPopulatedBitmaps = 0;
        for (int256 i = tickBitmapStart; i <= tickBitmapEnd; i++) {
            uint256 bitmap = pool.tickBitmap(int16(i));
            if (bitmap == 0) continue;
            numberOfPopulatedBitmaps++;
        }

        tickBitmap = new TickBitMapMappings[](numberOfPopulatedBitmaps);
        uint256 globalIndex = 0;
        for (int256 i = tickBitmapStart; i <= tickBitmapEnd; i++) {
            int16 index = int16(i);
            uint256 bitmap = pool.tickBitmap(index);
            if (bitmap == 0) continue;
            tickBitmap[globalIndex] = TickBitMapMappings({ index: index, value: bitmap });
            globalIndex++;
        }
    }

    function _calcTicksFromBitMap(
        IRamsesV3Pool pool, TickBitMapMappings[] memory tickBitmap
    ) internal view returns (TickInfoMappings[] memory ticks) {
        uint256 numberOfPopulatedTicks = 0;
        for (uint256 i = 0; i < tickBitmap.length; i++) {
            uint256 bitmap = tickBitmap[i].value;
            for (uint256 j = 0; j < 256; j++) {
                if (bitmap & (1 << j) > 0) numberOfPopulatedTicks++;
            }
        }

        ticks = new TickInfoMappings[](numberOfPopulatedTicks);
        int24 poolTickSpacing = pool.tickSpacing();

        uint256 globalIndex = 0;
        for (uint256 i = 0; i < tickBitmap.length; i++) {
            uint256 bitmap = tickBitmap[i].value;
            for (uint256 j = 0; j < 256; j++) {
                if (bitmap & (1 << j) > 0) {
                    int24 populatedTick = ((int24(int16(tickBitmap[i].index)) << 8) + int24(int256(j))) * poolTickSpacing;
                    ticks[globalIndex].index = populatedTick;
                    TickInfo memory info = ticks[globalIndex].value;
                    (
                        info.liquidityGross, info.liquidityNet, , ,
                        info.tickCumulativeOutside, info.secondsPerLiquidityOutsideX128,
                        info.secondsOutside, info.initialized
                    ) = pool.ticks(populatedTick);
                    globalIndex++;
                }
            }
        }
    }

    function _getPool(
        IRamsesV3Factory factory, address tokenIn, address tokenOut, int24 tickSpacing
    ) internal view returns (IRamsesV3Pool pool) {
        pool = IRamsesV3Pool(factory.getPool(tokenIn, tokenOut, tickSpacing));
        require(address(pool) != address(0), "Pool does not exist");
    }

    function _getBitmapIndexFromTick(int24 tick) internal pure returns (int16) {
        return int16(tick >> 8);
    }
}
