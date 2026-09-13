// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OAppUpgradeable, Origin, MessagingFee} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IRamsesMessageSender} from "../migration/interfaces/IRamsesMessageSender.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

interface IVeRam is IERC721 {
    function locked(uint256 _tokenId) external view returns (int128, uint256);
}

/// @title Airdrop user data structure
struct AirdropUser {
    uint256 veRamLocked;   // Minimum locked amount required for validation
    uint256 veRamVirtual;  // Amount to actually migrate (can include bonus)
}

/// @title Diamond storage library for RamsesMessageSender
library RamsesMessageSenderStorage {
    bytes32 internal constant SLOT = keccak256("ramses.sender.storage");

    struct Layout {
        /// @dev default gas for the LayerZero message
        uint128 defaultGas;
        /// @dev end time for the shuttle
        uint256 endTime;
        /// @dev paused state
        bool paused;
        /// @dev mapping of users and their airdrop data
        mapping(address => AirdropUser) airdropUsers;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }
}

contract RamsesMessageSender is IRamsesMessageSender, Initializable, OAppUpgradeable, ReentrancyGuardUpgradeable {
    using OptionsBuilder for bytes;

    /// @dev veRAM contract address on Arbitrum
    IVeRam public constant VE_RAM = IVeRam(0xAAA343032aA79eE9a6897Dab03bef967c3289a06);

    /// @dev dust threshold for balance mismatch due to rounding errors (1e18 wei)
    uint256 public constant DUST_THRESHOLD = 1e18;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    /// @notice Initializes the contract
    /// @param _delegate The delegate address for LayerZero operations
    function initialize(address _delegate) public initializer {
        __OApp_init(_delegate);
        __Ownable_init(_delegate);
        __ReentrancyGuard_init();

        RamsesMessageSenderStorage.Layout storage $ = RamsesMessageSenderStorage.layout();
        $.paused = true;
        $.defaultGas = 1_000_000;
    }

    /// @dev Getter functions for diamond storage
    function defaultGas() public view returns (uint128) {
        return RamsesMessageSenderStorage.layout().defaultGas;
    }

    function endTime() public view returns (uint256) {
        return RamsesMessageSenderStorage.layout().endTime;
    }

    function paused() public view returns (bool) {
        return RamsesMessageSenderStorage.layout().paused;
    }

    function airdropUsers(address user) public view returns (AirdropUser memory) {
        return RamsesMessageSenderStorage.layout().airdropUsers[user];
    }

    function veRamLocked(address user) public view returns (uint256) {
        return RamsesMessageSenderStorage.layout().airdropUsers[user].veRamLocked;
    }

    function veRamVirtual(address user) public view returns (uint256) {
        return RamsesMessageSenderStorage.layout().airdropUsers[user].veRamVirtual;
    }

    modifier checkEnd() {
        RamsesMessageSenderStorage.Layout storage $ = RamsesMessageSenderStorage.layout();
        require(block.timestamp < $.endTime, "ended");
        require(!$.paused, "paused");
        _;
    }

    /// @inheritdoc IRamsesMessageSender
    function shuttle(uint256 _veID) external payable nonReentrant checkEnd {
        RamsesMessageSenderStorage.Layout storage $ = RamsesMessageSenderStorage.layout();
        /// @dev requires the user approves their veRAM to the contract before-hand
        LocalParameters memory localPayload = _airdropHandler(msg.sender, _veID);
        /// @dev encodes the cross-chain message
        bytes memory _payload = abi.encode(localPayload);

        /**
         * Layerzero gas specs
         */
        uint128 gas = $.defaultGas;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);

        /// @dev internal bridge call
        // 30367 is the HyperEVM Mainnet endpoint ID from LayerZero
        _lzSend(30367, _payload, options, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    /// @dev internal version handler, compressing functionality to be encoding on a x-chain message
    function _airdropHandler(address _user, uint256 _veID) internal returns (LocalParameters memory relayMessage) {
        RamsesMessageSenderStorage.Layout storage $ = RamsesMessageSenderStorage.layout();
        AirdropUser memory userData = $.airdropUsers[_user];
        
        require(userData.veRamLocked > 0, "no balance");
        
        /// @dev fetch the veNFT's balance and verify it meets minimum requirement
        (int128 intBalance,) = VE_RAM.locked(_veID);
        uint256 trueBalance = uint256(uint128(intBalance));
        require(trueBalance >= userData.veRamLocked - DUST_THRESHOLD, "balance mismatch");
        require(VE_RAM.ownerOf(_veID) == _user, "not owner");
        
        /// @dev zero out allocation before external call
        $.airdropUsers[_user].veRamLocked = 0;
        $.airdropUsers[_user].veRamVirtual = 0;
        
        /// @dev transfer the veNFT to the contract
        VE_RAM.transferFrom(_user, address(this), _veID);

        return LocalParameters(_user, userData.veRamVirtual);
    }

    /// @dev collect veNFTs from migration for burning
    /// @inheritdoc IRamsesMessageSender
    function collect(address[] calldata _to, uint256[] calldata _veIDs) external onlyOwner nonReentrant {
        require(_to.length == _veIDs.length, "length mismatch");
        for (uint256 i = 0; i < _to.length; i++) {
            VE_RAM.transferFrom(address(this), _to[i], _veIDs[i]);
        }
    }

    /// @inheritdoc IRamsesMessageSender
    /// @param _users Array of user addresses
    /// @param _lockedAmounts Array of minimum veRAM locked amounts required for validation
    /// @param _virtualAmounts Array of virtual amounts to migrate (can include bonuses)
    function populate(
        address[] memory _users,
        uint256[] memory _lockedAmounts,
        uint256[] memory _virtualAmounts
    ) external onlyOwner {
        RamsesMessageSenderStorage.Layout storage $ = RamsesMessageSenderStorage.layout();
        require(_users.length == _lockedAmounts.length, "length mismatch");
        require(_users.length == _virtualAmounts.length, "length mismatch");
        
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            require($.airdropUsers[user].veRamLocked == 0, "user already populated");
            
            $.airdropUsers[user] = AirdropUser({
                veRamLocked: _lockedAmounts[i],
                veRamVirtual: _virtualAmounts[i]
            });
        }
    }

    function pause(bool _paused) external onlyOwner {
        RamsesMessageSenderStorage.Layout storage $ = RamsesMessageSenderStorage.layout();
        $.paused = _paused;
    }

    function overrideEndTime(uint256 _endTime) external onlyOwner {
        RamsesMessageSenderStorage.Layout storage $ = RamsesMessageSenderStorage.layout();
        $.endTime = _endTime;
    }

    function setDefaultGas(uint128 _defaultGas) external onlyOwner {
        RamsesMessageSenderStorage.Layout storage $ = RamsesMessageSenderStorage.layout();
        $.defaultGas = _defaultGas;
    }

    /// @dev override
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal virtual override {}
}
