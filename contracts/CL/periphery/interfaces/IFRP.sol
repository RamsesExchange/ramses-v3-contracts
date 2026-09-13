// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFRPMintCallback} from "./IFRPMintCallback.sol";

/// @title Fixed Range Position
/// @notice Fungible ownership of one immutable Ramses V3 concentrated-liquidity position.
interface IFRP is IERC20, IFRPMintCallback {
    event Initialized(
        address indexed payer,
        address indexed receiver,
        uint128 liquidity,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    event Minted(
        address indexed payer,
        address indexed receiver,
        uint256 shares,
        uint128 liquidityAdded,
        uint256 amount0,
        uint256 amount1
    );

    event Redeemed(
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint128 liquidityRemoved,
        uint256 amount0,
        uint256 amount1
    );

    error AlreadyInitialized();
    error NotInitialized();
    error NotBootstrapper(address caller);
    error DeadlineExpired(uint256 deadline);
    error InvalidAddress();
    error InvalidFactory();
    error InvalidPool();
    error PoolNotInitialized();
    error InvalidTicks();
    error InvalidShares();
    error InitialSharesExceedLiquidity(uint256 shares, uint128 liquidity);
    error InvalidLiquidity();
    error LiquidityDeltaTooLarge(uint256 liquidity);
    error Amount0MaxExceeded(uint256 amount0, uint256 amount0Max);
    error Amount1MaxExceeded(uint256 amount1, uint256 amount1Max);
    error Amount0MinNotMet(uint256 amount0, uint256 amount0Min);
    error Amount1MinNotMet(uint256 amount1, uint256 amount1Min);
    error UnauthorizedCallback(address caller);
    error CallbackInactive();
    error InvalidCallbackData();
    error InvalidCallbackPayer(address payer);
    error CallbackNotConsumed();
    error MintAmountsMismatch();
    error PositionLiquidityMismatch(uint128 expected, uint128 actual);
    error PrincipalCollectionMismatch();
    error TokenTransferMismatch(address token);

    function MINIMUM_SHARES() external view returns (uint256);

    function POSITION_INDEX() external view returns (uint256);

    function factory() external view returns (address);

    function pool() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function tickSpacing() external view returns (int24);

    function tickLower() external view returns (int24);

    function tickUpper() external view returns (int24);

    function bootstrapper() external view returns (address);

    function initialized() external view returns (bool);

    function positionKey() external view returns (bytes32);

    function positionLiquidity() external view returns (uint128 liquidity);

    /// @notice Seeds the immutable range and creates the initial FRP supply.
    /// @dev `initialShares` is the total initial supply and includes `MINIMUM_SHARES`, which are locked forever.
    ///      It cannot exceed `liquidity`; this keeps every nonzero share amount redeemable for active liquidity.
    ///      Bootstrap callers should choose a supply materially above `MINIMUM_SHARES` to keep the locked backing
    ///      economically negligible.
    function initialize(
        uint128 liquidity,
        uint256 initialShares,
        uint256 amount0Max,
        uint256 amount1Max,
        address receiver,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Mints an exact number of shares by adding proportional active liquidity and idle balances.
    function mint(uint256 shares, uint256 amount0Max, uint256 amount1Max, address receiver, uint256 deadline)
        external
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1);

    /// @notice Burns shares for proportional active liquidity, accrued fees, and idle balances.
    function redeem(uint256 shares, uint256 amount0Min, uint256 amount1Min, address receiver, uint256 deadline)
        external
        returns (uint128 liquidityRemoved, uint256 amount0, uint256 amount1);
}
