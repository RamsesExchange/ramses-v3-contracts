// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IDLMMFeeCollector {
    event TreasuryChanged(address oldTreasury, address newTreasury);

    event TreasuryFeesChanged(uint256 oldTreasuryFees, uint256 newTreasuryFees);

    event FeesCollected(
        address pool, uint256 feeDistAmountX, uint256 feeDistAmountY, uint256 treasuryAmountX, uint256 treasuryAmountY
    );

    function treasury() external returns (address);

    function treasuryFees() external returns (uint256);

    function setTreasury(address newTreasury) external;

    function setVoter(address newVoter) external;

    function setTreasuryFees(uint256 _treasuryFees) external;

    function collectProtocolFees(address pool) external;
}
