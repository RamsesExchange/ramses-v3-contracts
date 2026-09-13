// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";


/// @author https://ramses.xyz
/// @notice Ramses' native token on Ethereum Mainnet
contract Ramses is ERC20, ERC20Burnable, ERC20Permit {
    constructor() ERC20("Ramses", "RAM") ERC20Permit("Ramses") {
        /// @dev single mint with no minter perms forever for trustlessness.
        _mint(msg.sender, 1_000_000_000 * 1e18);
    }
}
