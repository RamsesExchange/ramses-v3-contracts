// SPDX-License-Identifier: kBUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFRP} from "./interfaces/IFRP.sol";
import {IFRPRamsesV3Factory} from "./interfaces/IFRPRamsesV3Factory.sol";
import {IFRPRamsesV3Pool} from "./interfaces/IFRPRamsesV3Pool.sol";

/// @title Fixed Range Position
/// @notice Tokenizes one immutable Ramses V3 concentrated-liquidity range into fungible ERC20 shares.
/// @dev FRP never swaps, rebalances, upgrades, or moves its liquidity to another range. Minting preserves active
///      liquidity and idle token balances per share independently, while redemption returns both pro rata.
contract FRP is ERC20, ReentrancyGuard, IFRP {
    using SafeERC20 for IERC20;

    uint256 public constant override MINIMUM_SHARES = 1_000;
    uint256 public constant override POSITION_INDEX = 0;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;
    // Ramses V3 casts each mint and burn liquidity delta to int128 internally.
    uint128 private constant MAX_LIQUIDITY_DELTA = 0x7fffffffffffffffffffffffffffffff;

    address public immutable override factory;
    address public immutable override pool;
    address public immutable override token0;
    address public immutable override token1;
    int24 public immutable override tickSpacing;
    int24 public immutable override tickLower;
    int24 public immutable override tickUpper;
    address public immutable override bootstrapper;

    bool public override initialized;

    address private callbackPayer;
    bool private callbackActive;
    uint256 private callbackAmount0;
    uint256 private callbackAmount1;

    constructor(
        address _factory,
        address _pool,
        int24 _tickLower,
        int24 _tickUpper,
        address _bootstrapper,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        if (_factory == address(0) || _pool == address(0) || _bootstrapper == address(0)) {
            revert InvalidAddress();
        }

        IFRPRamsesV3Pool pool_ = IFRPRamsesV3Pool(_pool);
        if (pool_.factory() != _factory) revert InvalidFactory();

        address token0_ = pool_.token0();
        address token1_ = pool_.token1();
        int24 tickSpacing_ = pool_.tickSpacing();

        if (token0_ == address(0) || token1_ == address(0) || token0_ == token1_ || tickSpacing_ <= 0) {
            revert InvalidPool();
        }

        IFRPRamsesV3Factory factory_ = IFRPRamsesV3Factory(_factory);
        if (!factory_.isPairV3(_pool) || factory_.getPool(token0_, token1_, tickSpacing_) != _pool) {
            revert InvalidPool();
        }

        if (
            _tickLower < MIN_TICK || _tickUpper > MAX_TICK || _tickLower >= _tickUpper || _tickLower % tickSpacing_ != 0
                || _tickUpper % tickSpacing_ != 0
        ) revert InvalidTicks();

        (uint160 sqrtPriceX96,,,,,,) = pool_.slot0();
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        factory = _factory;
        pool = _pool;
        token0 = token0_;
        token1 = token1_;
        tickSpacing = tickSpacing_;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        bootstrapper = _bootstrapper;
    }

    /// @inheritdoc IFRP
    function positionKey() public view override returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), POSITION_INDEX, tickLower, tickUpper));
    }

    /// @inheritdoc IFRP
    function positionLiquidity() public view override returns (uint128 liquidity) {
        (liquidity,,,,) = IFRPRamsesV3Pool(pool).positions(positionKey());
    }

    /// @inheritdoc IFRP
    function initialize(
        uint128 liquidity,
        uint256 initialShares,
        uint256 amount0Max,
        uint256 amount1Max,
        address receiver,
        uint256 deadline
    ) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (msg.sender != bootstrapper) revert NotBootstrapper(msg.sender);
        if (initialized) revert AlreadyInitialized();
        _checkDeadline(deadline);
        _checkReceiver(receiver);
        if (liquidity == 0) revert InvalidLiquidity();
        if (liquidity > MAX_LIQUIDITY_DELTA) revert LiquidityDeltaTooLarge(liquidity);
        if (initialShares <= MINIMUM_SHARES) revert InvalidShares();
        if (initialShares > liquidity) revert InitialSharesExceedLiquidity(initialShares, liquidity);

        uint128 liquidityBefore = positionLiquidity();
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        (amount0, amount1) = _mintLiquidity(liquidity, msg.sender);

        if (amount0 > amount0Max) revert Amount0MaxExceeded(amount0, amount0Max);
        if (amount1 > amount1Max) revert Amount1MaxExceeded(amount1, amount1Max);
        _checkIdleBalancesUnchanged(balance0Before, balance1Before);
        _checkPositionLiquidity(liquidityBefore + liquidity);

        initialized = true;
        _mint(address(this), MINIMUM_SHARES);
        _mint(receiver, initialShares - MINIMUM_SHARES);

        emit Initialized(msg.sender, receiver, liquidity, initialShares, amount0, amount1);
    }

    /// @inheritdoc IFRP
    function mint(uint256 shares, uint256 amount0Max, uint256 amount1Max, address receiver, uint256 deadline)
        external
        override
        nonReentrant
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        if (!initialized) revert NotInitialized();
        _checkDeadline(deadline);
        _checkReceiver(receiver);
        if (shares == 0) revert InvalidShares();

        _crystallizeAndCollectFees();

        uint256 supply = totalSupply();
        uint128 liquidityBefore = positionLiquidity();
        uint256 liquidityAdded256 = Math.mulDiv(liquidityBefore, shares, supply, Math.Rounding.Ceil);
        if (liquidityAdded256 == 0) revert InvalidLiquidity();
        if (liquidityAdded256 > MAX_LIQUIDITY_DELTA) revert LiquidityDeltaTooLarge(liquidityAdded256);
        // forge-lint: disable-next-line(unsafe-typecast)
        liquidityAdded = uint128(liquidityAdded256);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        uint256 idle0Added = Math.mulDiv(balance0Before, shares, supply, Math.Rounding.Ceil);
        uint256 idle1Added = Math.mulDiv(balance1Before, shares, supply, Math.Rounding.Ceil);

        (uint256 liquidityAmount0, uint256 liquidityAmount1) = _mintLiquidity(liquidityAdded, msg.sender);
        _checkIdleBalancesUnchanged(balance0Before, balance1Before);
        _checkPositionLiquidity(liquidityBefore + liquidityAdded);

        amount0 = liquidityAmount0 + idle0Added;
        amount1 = liquidityAmount1 + idle1Added;
        if (amount0 > amount0Max) revert Amount0MaxExceeded(amount0, amount0Max);
        if (amount1 > amount1Max) revert Amount1MaxExceeded(amount1, amount1Max);

        _transferFromExact(token0, msg.sender, address(this), idle0Added);
        _transferFromExact(token1, msg.sender, address(this), idle1Added);

        _mint(receiver, shares);
        emit Minted(msg.sender, receiver, shares, liquidityAdded, amount0, amount1);
    }

    /// @inheritdoc IFRP
    function redeem(uint256 shares, uint256 amount0Min, uint256 amount1Min, address receiver, uint256 deadline)
        external
        override
        nonReentrant
        returns (uint128 liquidityRemoved, uint256 amount0, uint256 amount1)
    {
        if (!initialized) revert NotInitialized();
        _checkDeadline(deadline);
        _checkReceiver(receiver);
        if (shares == 0) revert InvalidShares();

        _crystallizeAndCollectFees();

        uint256 supply = totalSupply();
        uint128 liquidityBefore = positionLiquidity();
        uint256 liquidityRemoved256 = Math.mulDiv(liquidityBefore, shares, supply);
        if (liquidityRemoved256 == 0) revert InvalidLiquidity();
        if (liquidityRemoved256 > MAX_LIQUIDITY_DELTA) revert LiquidityDeltaTooLarge(liquidityRemoved256);
        // forge-lint: disable-next-line(unsafe-typecast)
        liquidityRemoved = uint128(liquidityRemoved256);

        uint256 idleAmount0 = Math.mulDiv(IERC20(token0).balanceOf(address(this)), shares, supply);
        uint256 idleAmount1 = Math.mulDiv(IERC20(token1).balanceOf(address(this)), shares, supply);

        _burn(msg.sender, shares);

        IFRPRamsesV3Pool pool_ = IFRPRamsesV3Pool(pool);
        (uint256 principal0, uint256 principal1) = pool_.burn(POSITION_INDEX, tickLower, tickUpper, liquidityRemoved);
        _checkPositionLiquidity(liquidityBefore - liquidityRemoved);

        (uint256 collected0, uint256 collected1) = _collectAll();
        if (collected0 != principal0 || collected1 != principal1) revert PrincipalCollectionMismatch();

        amount0 = idleAmount0 + collected0;
        amount1 = idleAmount1 + collected1;
        if (amount0 < amount0Min) revert Amount0MinNotMet(amount0, amount0Min);
        if (amount1 < amount1Min) revert Amount1MinNotMet(amount1, amount1Min);

        _transferExact(token0, receiver, amount0);
        _transferExact(token1, receiver, amount1);

        emit Redeemed(msg.sender, receiver, shares, liquidityRemoved, amount0, amount1);
    }

    /// @notice Pays the immutable pool during an FRP liquidity mint.
    /// @dev The callback is active only during an FRP-initiated pool mint and authenticates both pool and payer.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        if (msg.sender != pool) revert UnauthorizedCallback(msg.sender);
        if (!callbackActive) revert CallbackInactive();
        if (data.length != 32) revert InvalidCallbackData();

        address payer = abi.decode(data, (address));
        if (payer != callbackPayer) revert InvalidCallbackPayer(payer);

        callbackActive = false;
        callbackAmount0 = amount0Owed;
        callbackAmount1 = amount1Owed;

        _transferFromExact(token0, payer, pool, amount0Owed);
        _transferFromExact(token1, payer, pool, amount1Owed);
    }

    function _mintLiquidity(uint128 liquidity, address payer) private returns (uint256 amount0, uint256 amount1) {
        callbackPayer = payer;
        callbackAmount0 = 0;
        callbackAmount1 = 0;
        callbackActive = true;

        (amount0, amount1) = IFRPRamsesV3Pool(pool)
            .mint(address(this), POSITION_INDEX, tickLower, tickUpper, liquidity, abi.encode(payer));

        if (callbackActive) revert CallbackNotConsumed();
        if (amount0 != callbackAmount0 || amount1 != callbackAmount1) revert MintAmountsMismatch();

        callbackPayer = address(0);
        callbackAmount0 = 0;
        callbackAmount1 = 0;
    }

    function _crystallizeAndCollectFees() private {
        uint128 liquidityBefore = positionLiquidity();
        IFRPRamsesV3Pool(pool).burn(POSITION_INDEX, tickLower, tickUpper, 0);
        _checkPositionLiquidity(liquidityBefore);
        _collectAll();
    }

    function _collectAll() private returns (uint256 amount0, uint256 amount1) {
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        (uint128 collected0, uint128 collected1) = IFRPRamsesV3Pool(pool)
            .collect(address(this), POSITION_INDEX, tickLower, tickUpper, type(uint128).max, type(uint128).max);

        uint256 balance0After = IERC20(token0).balanceOf(address(this));
        uint256 balance1After = IERC20(token1).balanceOf(address(this));
        if (balance0After < balance0Before || balance0After - balance0Before != collected0) {
            revert TokenTransferMismatch(token0);
        }
        if (balance1After < balance1Before || balance1After - balance1Before != collected1) {
            revert TokenTransferMismatch(token1);
        }

        amount0 = collected0;
        amount1 = collected1;
    }

    function _transferFromExact(address token, address from, address to, uint256 amount) private {
        if (amount == 0) return;

        uint256 fromBalanceBefore = IERC20(token).balanceOf(from);
        uint256 toBalanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransferFrom(from, to, amount);
        uint256 fromBalanceAfter = IERC20(token).balanceOf(from);
        uint256 toBalanceAfter = IERC20(token).balanceOf(to);

        if (
            fromBalanceAfter > fromBalanceBefore || toBalanceAfter < toBalanceBefore
                || fromBalanceBefore - fromBalanceAfter != amount || toBalanceAfter - toBalanceBefore != amount
        ) revert TokenTransferMismatch(token);
    }

    function _transferExact(address token, address to, uint256 amount) private {
        if (amount == 0) return;

        uint256 fromBalanceBefore = IERC20(token).balanceOf(address(this));
        uint256 toBalanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransfer(to, amount);
        uint256 fromBalanceAfter = IERC20(token).balanceOf(address(this));
        uint256 toBalanceAfter = IERC20(token).balanceOf(to);

        if (
            fromBalanceAfter > fromBalanceBefore || toBalanceAfter < toBalanceBefore
                || fromBalanceBefore - fromBalanceAfter != amount || toBalanceAfter - toBalanceBefore != amount
        ) revert TokenTransferMismatch(token);
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
    }

    function _checkReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
    }

    function _checkIdleBalancesUnchanged(uint256 expected0, uint256 expected1) private view {
        if (IERC20(token0).balanceOf(address(this)) != expected0) revert TokenTransferMismatch(token0);
        if (IERC20(token1).balanceOf(address(this)) != expected1) revert TokenTransferMismatch(token1);
    }

    function _checkPositionLiquidity(uint128 expected) private view {
        uint128 actual = positionLiquidity();
        if (actual != expected) revert PositionLiquidityMismatch(expected, actual);
    }
}
