// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFeeRecipientFactory} from "../interfaces/IFeeRecipientFactory.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IAccessHub} from "contracts/interfaces/IAccessHub.sol";
import {Errors} from "contracts/libraries/Errors.sol";
import {FeeRecipient} from "./../FeeRecipient.sol";

contract FeeRecipientFactory is IFeeRecipientFactory {
    uint256 internal constant FEE_DENOM = 1_000_000;

    /// @inheritdoc IFeeRecipientFactory
    address public lastFeeRecipient;

    /// @inheritdoc IFeeRecipientFactory
    address public treasury;

    address public voter;

    IAccessHub public accessHub;

    /// @inheritdoc IFeeRecipientFactory
    uint256 public feeToTreasury;

    /// @inheritdoc IFeeRecipientFactory
    mapping(address pair => address feeRecipient) public feeRecipientForPair;

    event SetFeeToTreasury(uint256 indexed feeToTreasury);
    event SetTreasury(address indexed treasury);
    event SetVoter(address indexed voter);

    modifier onlyGovernance() {
        require(msg.sender == address(accessHub), Errors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    constructor(IAccessHub _accessHub) {
        accessHub = _accessHub;
        treasury = _accessHub.treasury();
        voter = address(_accessHub.voter());
    }

    /// @inheritdoc IFeeRecipientFactory
    function createFeeRecipient(address pair) external returns (address _feeRecipient) {
        /// @dev ensure caller is the voter
        require(msg.sender == voter, Errors.NOT_AUTHORIZED(msg.sender));
        /// @dev create a new feeRecipient
        _feeRecipient = address(new FeeRecipient(pair, msg.sender, address(this)));
        /// @dev dont need to ensure that a feeRecipient wasn't already made previously
        feeRecipientForPair[pair] = _feeRecipient;
        lastFeeRecipient = _feeRecipient;
    }

    /// @inheritdoc IFeeRecipientFactory
    function setFeeToTreasury(uint256 _feeToTreasury) external onlyGovernance {
        /// @dev ensure fee to treasury isn't too high
        require(_feeToTreasury <= FEE_DENOM, Errors.INVALID_TREASURY_FEE());
        feeToTreasury = _feeToTreasury;
        emit SetFeeToTreasury(_feeToTreasury);
    }

    /// @inheritdoc IFeeRecipientFactory
    function setTreasury(address _treasury) external onlyGovernance {
        treasury = _treasury;
        emit SetTreasury(_treasury);   
    }

    function setVoter(address _voter) external onlyGovernance {
        voter = _voter;
        emit SetVoter(_voter);
    }


}
