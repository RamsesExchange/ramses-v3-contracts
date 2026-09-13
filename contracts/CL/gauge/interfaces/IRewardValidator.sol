// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRewardValidator {
    /**
     * @notice Validates whether a reward claim should be allowed or slashed
     * @param _owner The owner of the position
     * @param _receiver The intended receiver of the rewards
     * @param _positionHash The hash of the position
     * @param _origin The tx.origin of the transaction
     * @param _index The index/tokenId of the position
     * @param _tickLower The lower tick of the position
     * @param _tickUpper The upper tick of the position
     * @return bool Returns true if the reward should be slashed to r33, false if normal claim
     */
    function validateReward(
        address _owner,
        address _receiver,
        bytes32 _positionHash,
        address _origin,
        uint256 _index,
        int24 _tickLower,
        int24 _tickUpper,
        address _pool
    ) external view returns (bool);

    /**
     * @notice Update the NFP manager address
     * @param _newNfpManager The new RamsesV3PositionManager address
     */
    function setNfpManager(address _newNfpManager) external;

    /**
     * @notice Update the voter address
     * @param _newVoter The new Voter address
     */
    function setVoter(address _newVoter) external;

    /**
     * @notice Update the AccessHub address
     * @param _newAccessHub The new AccessHub address
     */
    function setAccessHub(address _newAccessHub) external;
}