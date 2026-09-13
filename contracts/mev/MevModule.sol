// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IXRam} from "contracts/interfaces/IXRam.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAccessHub} from "contracts/interfaces/IAccessHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISwapRouter} from "contracts/CL/periphery/interfaces/ISwapRouter.sol";
import {IFeeDistributor} from "contracts/interfaces/IFeeDistributor.sol";
import {IRamsesV3Pool} from "contracts/CL/core/interfaces/IRamsesV3Pool.sol";
import {IWETH} from "contracts/interfaces/IWETH.sol";
import {IPairFactory} from "contracts/interfaces/IPairFactory.sol";
import {IPair} from "contracts/interfaces/IPair.sol";
import {IRouter} from "contracts/interfaces/IRouter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 *
 * ███╗   ███╗███████╗██╗   ██╗
 * ████╗ ████║██╔════╝██║   ██║
 * ██╔████╔██║█████╗  ██║   ██║
 * ██║╚██╔╝██║██╔══╝  ╚██╗ ██╔╝
 * ██║ ╚═╝ ██║███████╗ ╚████╔╝ 
 * ╚═╝     ╚═╝╚══════╝  ╚═══╝  
 *
 * ███╗   ███╗ ██████╗ ██████╗ ██╗   ██╗██╗     ███████╗
 * ████╗ ████║██╔═══██╗██╔══██╗██║   ██║██║     ██╔════╝
 * ██╔████╔██║██║   ██║██║  ██║██║   ██║██║     █████╗  
 * ██║╚██╔╝██║██║   ██║██║  ██║██║   ██║██║     ██╔══╝  
 * ██║ ╚═╝ ██║╚██████╔╝██████╔╝╚██████╔╝███████╗███████╗
 * ╚═╝     ╚═╝ ╚═════╝ ╚═════╝  ╚═════╝ ╚══════╝╚══════╝  v0.0.1
 *
 * @title      RamsesMevModule
 * @notice     Permissioned MEV module for transparent protocol revenue generation
 * 
 * @dev        [CORE FUNCTIONALITY]
 *             =====================
 *             Authorization:
 *             - Only AuthorizedExecutors can use this module
 *             - Fees can only be switched to complete a full arbitrage cycle atomically
 *             - Arbitrary fee switching is forbidden
 *             Revenue share:
 *             - Full transparency
 *             - 100% of proceeds distributed directly to voters via vote bribes
 *             - No other withdrawal methods possible
 *   
 */

contract MevModule is Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// constants
    address public constant RAM = 0x555570a286F15EbDFE42B66eDE2f724Aa1AB5555;
    address public constant XRAM = 0xAE6D5FcE541216BDA471D311425B5412D9f1DEb9;
    address public constant X33 = 0x5555c2542836e7a6c8D3E133D5AA9773b65D5555;
    address public constant WETH = 0x5555555555555555555555555555555555555555;
    address public constant RAMSES_MULTISIG = 0x20D630cF1f5628285BfB91DfaC8C89eB9087BE1A;
    uint256 public constant INVENTORY_FLOOR = 500 * 1e18;

    /// storage
    EnumerableSet.AddressSet private _authorizedExecutors;
    IAccessHub public accessHub;
    ISwapRouter public swapRouter;
    IPairFactory public pairFactory;
    IRouter public legacyRouter;
    uint256 public totalBuybackAndBurned;

    

    /// types
    struct AuthorizedSwapParams {
        address[] poolAddresses;
        uint24[] originalFees; // deprecated: kept for backward compatibility
        uint24[] targetFees;
        bool[] concentrated;
    }
    struct SwapIntent {
        address tokenIn;
        address tokenOut;
        int24 feeOrTickspace;
        PoolType poolType;
    }

    enum PoolType {
        LEGACY_STABLE,
        LEGACY_VOLATILE,
        V3
    }
    enum PayloadType {
        ROUTER,
        EXECUTOR
    }
    
    /// errors
    error Unauthorized();
    error Unprofitable(uint256 initialBalance, uint256 finalBalance);
    error NotImplemented();
    /// events
    event BuybackAndBurn(uint256 amountIn, uint256 amountOut);
    /// constructors
    constructor() {
        _disableInitializers();
    }

    /// initializers
    function initialize() external initializer {
        _authorizedExecutors.add(0xAAA5D87392652647225B96563e469768f000b9De);
        swapRouter = ISwapRouter(0x76D91074B46fF76E04FE59a90526a40009943fd2);
        accessHub = IAccessHub(	0x6631a487d59893831b331653225E0bfeBf6Ea1EC);
        IERC20(RAM).approve(address(swapRouter), type(uint256).max);
        pairFactory = IPairFactory(0xd0a07E160511c40ccD5340e94660E9C9c01b0D27);
        legacyRouter = IRouter(0xdcC44285fBc236457A5cd91C2f77AD8421B0D8ED);
    }

    /// modifiers
    modifier onlyAuthorizedExecutor() {
        if (!_authorizedExecutors.contains(msg.sender)) revert Unauthorized();
        _;
    }
    modifier onlyMultisig() {
        if (msg.sender != accessHub.treasury()) revert Unauthorized();
        _;
    }
    
    /*━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     *                  AUTHORIZATION            
     *━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━*/
    function addAuthorizedExecutor(address _executor, bool _isActive) external onlyMultisig {        
        if (_isActive) {
            if (!_authorizedExecutors.contains(_executor)) {
                _authorizedExecutors.add(_executor);
            }
        } else {
            if (_authorizedExecutors.contains(_executor)) {
                _authorizedExecutors.remove(_executor);
            }
        }
    }
    function isAuthorizedExecutor(address _executor) external view returns (bool) {
        return _authorizedExecutors.contains(_executor);
    }
    function authorizedExecutorsCount() external view returns (uint256) {
        return _authorizedExecutors.length();
    }
    modifier authorizedSwap(
        AuthorizedSwapParams calldata _authParams
    ) {
        // capture original fair fees
        uint24[] memory originalFees = new uint24[](_authParams.poolAddresses.length);
        for (uint256 i = 0; i < _authParams.poolAddresses.length; i++) {
            if (_authParams.concentrated[i]) {
                // V3 uint24
                originalFees[i] = IRamsesV3Pool(_authParams.poolAddresses[i]).fee();
            } else {
                // legacy uint256
                originalFees[i] = uint24(IPair(_authParams.poolAddresses[i]).fee());
            }
        }

        // execute
        accessHub.setSwapFees(_authParams.poolAddresses, _authParams.targetFees);
        _;
        accessHub.setSwapFees(_authParams.poolAddresses, originalFees);
    }

    /*━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     *                     MEV                    
     *━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━*/
    function computeV3Address(address deployer, address token0, address token1, int24 tickSpacing) internal pure returns (address pool) {
        require(token0 < token1, "!TokenOrder");
        bytes32 POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex'ff',
                            deployer,
                            keccak256(abi.encode(token0, token1, tickSpacing)),
                            POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    function initApprovals() external {
        IERC20(RAM).approve(address(XRAM), type(uint256).max);
        IERC20(XRAM).approve(X33, type(uint256).max);
    }

    function amo(
        ISwapRouter.ExactInputSingleParams calldata _swapParams,
        AuthorizedSwapParams calldata _authParams,
        bool _simulate,
        bool _ceiling
    )
        external
        onlyAuthorizedExecutor
        authorizedSwap(_authParams)
    {

        if (_ceiling) {
           /// snapshot ram inventory
           uint256 balanceBefore = IERC20(RAM).balanceOf(address(this));
           /// ram -> xram
           IXRam(XRAM).convertEmissionsToken(_swapParams.amountIn);
           /// xram -> x33
           IERC4626(X33).deposit(_swapParams.amountIn, address(this));
           /// x33 -> ram swap for profit
           swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn: _swapParams.tokenIn,
                tokenOut: _swapParams.tokenOut,
                tickSpacing: _swapParams.tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: IERC20(X33).balanceOf(address(this)),
                amountOutMinimum: _swapParams.amountOutMinimum,
                sqrtPriceLimitX96: _swapParams.sqrtPriceLimitX96
            }));
            uint256 balanceAfter = IERC20(RAM).balanceOf(address(this));
            // short circuit if not profitable or simulation
            if (balanceAfter <= balanceBefore || _simulate) {
                revert Unprofitable(balanceBefore, balanceAfter);
            }
        }
        /// floor arbitrage, we buy x33 with RAM and redeem it for more RAM
        else {
            // snapshot ram inventory
            uint256 balanceBefore = IERC20(RAM).balanceOf(address(this));
            // optimal swap
            uint256 amountOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn: _swapParams.tokenIn,
                tokenOut: _swapParams.tokenOut,
                tickSpacing: _swapParams.tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _swapParams.amountIn,
                amountOutMinimum: _swapParams.amountOutMinimum,
                sqrtPriceLimitX96: _swapParams.sqrtPriceLimitX96
            }));
            // x33 -> xram
            IERC4626(X33).redeem(amountOut, address(this), address(this));
            // xram -> ram
            IXRam(XRAM).exit(IERC20(XRAM).balanceOf(address(this)));
            // profit check
            uint256 balanceAfter = IERC20(RAM).balanceOf(address(this));
            // short circuit if not profitable or simulation
            if (balanceAfter <= balanceBefore || _simulate) {
                revert Unprofitable(balanceBefore, balanceAfter);
            }
        }
    }


    function backrun(
        PayloadType _payloadType,
        SwapIntent[] calldata _swapIntents,
        uint256 _amountIn,
        AuthorizedSwapParams calldata _authParams,
        bool _simulate
    )   
        external
        onlyAuthorizedExecutor
        authorizedSwap(_authParams)
        returns (uint256 _quoteOut)
    {   
        uint256 balanceBefore = IERC20(WETH).balanceOf(address(this));
        uint256 amountIn;
        uint256 amountOut;
        
        // 0 = ROUTER PAYLOAD
        if (_payloadType == PayloadType.ROUTER) {
            for (uint256 i = 0; i < _swapIntents.length; i++) {
                SwapIntent memory swapIntent = _swapIntents[i];
                // first swap
                if (i == 0) {
                    amountIn = _amountIn;
                }

                // legacy intent
                if (swapIntent.poolType == PoolType.LEGACY_STABLE || swapIntent.poolType == PoolType.LEGACY_VOLATILE) {
                    IRouter.route[] memory routes = new IRouter.route[](1);
                    routes[0] = IRouter.route({
                        from: swapIntent.tokenIn,
                        to: swapIntent.tokenOut,
                        stable: swapIntent.poolType == PoolType.LEGACY_STABLE 
                    });
                    uint256[] memory amounts = legacyRouter.swapExactTokensForTokens(
                        amountIn,
                        0,
                        routes,
                        address(this),
                        block.timestamp
                    );
                    amountOut = amounts[amounts.length - 1];
                }

                // univ3 intent
                else {
                    amountOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                        tokenIn: swapIntent.tokenIn,
                        tokenOut: swapIntent.tokenOut,
                        tickSpacing: swapIntent.feeOrTickspace,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: amountIn,
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    }));
                }

                // amountOut becomes input for next swap intent
                amountIn = amountOut;
            }
            uint256 balanceAfter = IERC20(WETH).balanceOf(address(this));
            // if simulating, always return the raw quote (meant to be statically called)
            if (_simulate) {
                return amountOut;
            }
            // short circuit if not profitable
            if (balanceAfter <= balanceBefore) {
                revert Unprofitable(balanceBefore, balanceAfter);
            }

        }
        // 1 = EXECUTOR PAYLOAD
        if (_payloadType == PayloadType.EXECUTOR) {
            revert NotImplemented();
        }
    }

    /// @dev Quote an authorizedSwap (meant to be statically called)
    function singleQuoteAuthorizedSwap(
        SwapIntent calldata _swapIntent,
        uint256 _amountIn,
        AuthorizedSwapParams calldata _authParams,
        bool _transferFromCaller
    )
        external
        onlyAuthorizedExecutor
        authorizedSwap(_authParams)
        returns (uint256 _quoteOut)

    {
        address tokenIn = _swapIntent.tokenIn;
        
        if (_transferFromCaller) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), _amountIn);
        }

        // legacy intent
        if (_swapIntent.poolType == PoolType.LEGACY_STABLE || _swapIntent.poolType == PoolType.LEGACY_VOLATILE) {
            IRouter.route[] memory routes = new IRouter.route[](1);
            routes[0] = IRouter.route({
                from: _swapIntent.tokenIn,
                to: _swapIntent.tokenOut,
                stable: _swapIntent.poolType == PoolType.LEGACY_STABLE 
            });
            uint256[] memory amounts = legacyRouter.swapExactTokensForTokens(
                _amountIn,
                0,
                routes,
                address(this),
                block.timestamp
            );
            _quoteOut = amounts[amounts.length - 1];
        }

        // univ3 intent
        else {
            _quoteOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn: _swapIntent.tokenIn,
                tokenOut: _swapIntent.tokenOut,
                tickSpacing: _swapIntent.feeOrTickspace,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            }));
        }

        return _quoteOut;
    }





    function sanitizeApprovals(address[] calldata _tokens) external onlyAuthorizedExecutor {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (IERC20(_tokens[i]).allowance(address(this), address(legacyRouter)) < type(uint256).max / 2) {
                IERC20(_tokens[i]).approve(address(legacyRouter), type(uint256).max);
            }
            if (IERC20(_tokens[i]).allowance(address(this), address(swapRouter)) < type(uint256).max / 2) {
                IERC20(_tokens[i]).approve(address(swapRouter), type(uint256).max);
            }
        }
    }

    function runback() external onlyAuthorizedExecutor {
        uint256 balance = IERC20(WETH).balanceOf(address(this));
        require(balance > INVENTORY_FLOOR, "BELOW_FLOOR");

        uint256 excess = balance - INVENTORY_FLOOR;

        IWETH(WETH).withdraw(excess);

        (bool success, ) = msg.sender.call{value: excess}("");
        require(success, "TRANSFER_FAILED");
    }

    receive() external payable {}

    function setLegacyRouter(address _legacyRouter) external onlyMultisig {
        legacyRouter = IRouter(_legacyRouter);
    }

    function setSwapRouter(address _swapRouter) external onlyMultisig {
        swapRouter = ISwapRouter(_swapRouter);
    }

    /**
     * @notice Rescue ERC20 tokens stuck in the contract
     * @dev Only callable by the multisig
     * @param _token The ERC20 token address to rescue
     * @param _amount The amount of tokens to transfer
     */
    function clawBackToMultisig(address _token, uint256 _amount) external onlyMultisig {
        IERC20(_token).transfer(RAMSES_MULTISIG, _amount);
    }
}

