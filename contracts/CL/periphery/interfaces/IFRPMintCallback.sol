// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @title Callback for minting liquidity into a Fixed Range Position
/// @notice Implemented by FRP and called only by its immutable Ramses V3 pool.
interface IFRPMintCallback {
    /// @notice Pays the pool for liquidity requested by FRP.
    /// @param amount0Owed Amount of token0 owed to the pool.
    /// @param amount1Owed Amount of token1 owed to the pool.
    /// @param data Encoded payer address supplied by FRP.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}
