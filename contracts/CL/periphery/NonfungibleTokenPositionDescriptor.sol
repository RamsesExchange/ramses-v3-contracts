// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
pragma abicoder v2;

import '../core/interfaces/IRamsesV3Pool.sol';

import './libraries/SafeERC20Namer.sol';
import './libraries/ChainId.sol';
import './interfaces/INonfungiblePositionManager.sol';
import './interfaces/INonfungibleTokenPositionDescriptor.sol';
import './interfaces/IERC20Metadata.sol';
import './libraries/PoolAddress.sol';
import './libraries/NFTDescriptor.sol';
import './libraries/TokenRatioSortOrder.sol';

/// @title Describes NFT token positions
/// @notice Produces a string containing the data URI for a JSON metadata string
contract NonfungibleTokenPositionDescriptor is INonfungibleTokenPositionDescriptor {
    address public immutable WETH9;
    /// @dev A null-terminated string
    string public constant NATIVE_CURRENCY_LABEL = 'ETH';

    constructor(address _WETH9) {
        WETH9 = _WETH9;
    }

    /// @notice Returns the native currency label as a string
    function nativeCurrencyLabel() public pure returns (string memory) {
        return NATIVE_CURRENCY_LABEL;
    }

    /// @inheritdoc INonfungibleTokenPositionDescriptor
    function tokenURI(
        INonfungiblePositionManager positionManager,
        uint256 tokenId
    ) external view override returns (string memory) {
        (
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            ,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);

        IRamsesV3Pool pool = IRamsesV3Pool(
            PoolAddress.computeAddress(
                positionManager.deployer(),
                PoolAddress.PoolKey({token0: token0, token1: token1, tickSpacing: tickSpacing})
            )
        );

        bool _flipRatio = flipRatio(token0, token1);
        address quoteTokenAddress = !_flipRatio ? token1 : token0;
        address baseTokenAddress = !_flipRatio ? token0 : token1;
        (, int24 tick, , , , , ) = pool.slot0();

        return
            NFTDescriptor.constructTokenURI(
                NFTDescriptor.ConstructTokenURIParams({
                    tokenId: tokenId,
                    quoteTokenAddress: quoteTokenAddress,
                    baseTokenAddress: baseTokenAddress,
                    quoteTokenSymbol: quoteTokenAddress == WETH9
                        ? nativeCurrencyLabel()
                        : SafeERC20Namer.tokenSymbol(quoteTokenAddress),
                    baseTokenSymbol: baseTokenAddress == WETH9
                        ? nativeCurrencyLabel()
                        : SafeERC20Namer.tokenSymbol(baseTokenAddress),
                    quoteTokenDecimals: IERC20Metadata(quoteTokenAddress).decimals(),
                    baseTokenDecimals: IERC20Metadata(baseTokenAddress).decimals(),
                    flipRatio: _flipRatio,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    tickCurrent: tick,
                    tickSpacing: pool.tickSpacing(),
                    fee: pool.fee(),
                    poolAddress: address(pool)
                })
            );
    }

    function flipRatio(address token0, address token1 /*uint256 chainId*/) public view returns (bool) {
        return tokenRatioPriority(token0) > tokenRatioPriority(token1);
    }

    function tokenRatioPriority(address token /*, uint256 chainId*/) public view returns (int256) {
        if (token == WETH9) {
            return TokenRatioSortOrder.DENOMINATOR;
        }
        return 0;
    }
}
