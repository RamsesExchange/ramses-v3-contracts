// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @title Minimal Ramses V3 factory interface used by FRP
interface IFRPRamsesV3Factory {
    /// @notice Returns the canonical pool for a token pair and tick spacing.
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);

    /// @notice Returns whether an address is a Ramses V3 pool registered by the factory.
    function isPairV3(address pool) external view returns (bool);
}
