// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Extended} from "contracts/interfaces/IERC20Extended.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// *** ************************ //
// Error strings                //
error InvalidNonce();
error NoTokensProvided();
error TooManyAssets();
error LengthMismatch();
error TokenNotAllowed();
error SlippageExceeded();
error InvalidThreshold();
error InvalidMaxClaim();
// **************************** //

/// @title Ramses: Sarcophagus
/// @notice Burns a predefined threshold of RAM in exchange for accumulated protocol fees
contract Sarcophagus is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20Extended;

    IERC20Extended public immutable RAM;

    uint256 public immutable CHAIN_ID;

    /// @notice the amount of RAM consumed to be able to claim the fees
    uint256 public exchangeAmountThreshold;
    /// @notice the maximum number of tokens that can be claimed at once
    uint256 public maxTokenClaim;
    /// @notice the nonce for the transaction ordering
    uint256 public nonce;

    /// @notice mapping of allowed tokens to claim
    mapping(address => bool) public isAllowed;

    event Buried(uint256 indexed nonce, address indexed user, address[] tokensClaimed);

    /// @notice increments nonce for transaction ordering
    /// @dev basically lets searchers can claim tokens at a known state not getting rekt completely
    modifier handleNonce(uint256 _nonce) {
        require(_nonce == nonce, InvalidNonce());
        unchecked {
            ++nonce;
        }
        _;
    }

    constructor(address _owner, address _ram) Ownable(_owner) {
        RAM = IERC20Extended(_ram);
        CHAIN_ID = block.chainid;
        /// @dev default values, can change later as needed
        maxTokenClaim = 20;
        exchangeAmountThreshold = 100_000 * 1e18;
    }

    /// @notice Burns RAM in exchange for accumulated fees
    /// @param _nonce Must match current nonce
    /// @param _tokens Whitelisted tokens to claim
    /// @param _minAmountsOut Minimum amounts (slippage protection)
    function bury(uint256 _nonce, address[] calldata _tokens, uint256[] calldata _minAmountsOut)
        external
        nonReentrant
        handleNonce(_nonce)
    {
        uint256 len = _tokens.length;
        require(len > 0, NoTokensProvided());
        require(len <= maxTokenClaim, TooManyAssets());
        require(len == _minAmountsOut.length, LengthMismatch());

        for (uint256 i; i < len;) {
            require(isAllowed[_tokens[i]], TokenNotAllowed());
            unchecked {
                ++i;
            }
        }

        RAM.safeTransferFrom(msg.sender, address(this), exchangeAmountThreshold);
        /// @dev if we exist on the canonical RAM chain (Ethereum Mainnet)
        /// @dev we burn the RAM properly, otherwise if not on Mainnet we hold the tokens inside a BurningEscrow which then is later burned on Mainnet
        if (CHAIN_ID == 1) {
            RAM.burn(exchangeAmountThreshold);
        } else {
            RAM.safeTransfer(address(0xdead), exchangeAmountThreshold);
        }

        for (uint256 i; i < len;) {
            IERC20Extended t = IERC20Extended(_tokens[i]);
            uint256 bal = t.balanceOf(address(this));
            require(bal >= _minAmountsOut[i], SlippageExceeded());
            if (bal > 0) t.safeTransfer(msg.sender, bal);
            unchecked {
                ++i;
            }
        }

        emit Buried(_nonce, msg.sender, _tokens);
    }

    function rescue(address _token, address _to, uint256 _amount) external onlyOwner {
        IERC20Extended(_token).safeTransfer(_to, _amount);
    }

    function setExchangeAmountThreshold(uint256 _exchangeAmountThreshold) external onlyOwner {
        require(_exchangeAmountThreshold > 0, InvalidThreshold());
        exchangeAmountThreshold = _exchangeAmountThreshold;
    }

    function setMaxTokenClaim(uint256 _maxTokenClaim) external onlyOwner {
        require(_maxTokenClaim > 0, InvalidMaxClaim());
        maxTokenClaim = _maxTokenClaim;
    }

    function setAllowedTokens(address[] calldata _tokens, bool[] calldata _allowed) external onlyOwner {
        uint256 len = _tokens.length;
        require(len == _allowed.length, LengthMismatch());
        for (uint256 i; i < len;) {
            isAllowed[_tokens[i]] = _allowed[i];
            unchecked {
                ++i;
            }
        }
    }
}
