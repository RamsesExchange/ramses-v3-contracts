// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title R33OftLockbox
/// @notice LayerZero OFT adapter for the existing canonical r33 token on HyperEVM.
/// @dev r33 shares are locked here when bridging out and released when bridging back.
///      Deploy exactly one lockbox for the canonical r33 token.
contract R33OftLockbox is OFTAdapter {
    constructor(address r33Token, address lzEndpoint, address delegate)
        OFTAdapter(r33Token, lzEndpoint, delegate)
        Ownable(delegate)
    {}
}
