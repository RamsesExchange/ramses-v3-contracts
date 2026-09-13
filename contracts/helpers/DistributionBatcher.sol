// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVoter} from "../interfaces/IVoter.sol";

/**
 * @title DistributionBatcher
 * @notice A simple helper contract to batch distribute() calls with try/catch protection
 * @dev Prevents individual gauge distribution failures from reverting the entire batch
 */
contract DistributionBatcher {
    /// @notice The Voter contract address
    IVoter public immutable voter;

    /// @notice Emitted when a distribution succeeds for a gauge
    event DistributionSuccess(address indexed gauge);

    /// @notice Emitted when a distribution fails for a gauge
    event DistributionFailure(address indexed gauge, bytes reason);

    constructor(address _voter) {
        require(_voter != address(0), "Invalid voter address");
        voter = IVoter(_voter);
    }

    /**
     * @notice Get the total number of gauges from Voter
     * @return Total number of gauges
     */
    function getGaugesLength() external view returns (uint256) {
        return voter.getGaugesLength();
    }

    /**
     * @notice Distribute to all gauges with try/catch protection
     * @return successCount Number of successful distributions
     * @return failureCount Number of failed distributions
     */
    function distributeAll()
        external
        returns (uint256 successCount, uint256 failureCount)
    {
        uint256 gaugesLength = voter.getGaugesLength();

        for (uint256 i = 0; i < gaugesLength; i++) {
            address gauge = voter.getGauge(i);
            try voter.distribute(gauge) {
                successCount++;
                emit DistributionSuccess(gauge);
            } catch (bytes memory reason) {
                failureCount++;
                emit DistributionFailure(gauge, reason);
            }
        }
    }

    /**
     * @notice Distribute to gauges by index range with try/catch protection
     * @param startIndex Starting index (inclusive)
     * @param endIndex Ending index (exclusive)
     * @return successCount Number of successful distributions
     * @return failureCount Number of failed distributions
     */
    function batchDistributeByIndex(uint256 startIndex, uint256 endIndex)
        external
        returns (uint256 successCount, uint256 failureCount)
    {
        uint256 gaugesLength = voter.getGaugesLength();

        // Cap endIndex at gaugesLength
        if (endIndex > gaugesLength) {
            endIndex = gaugesLength;
        }

        require(startIndex < endIndex, "Invalid range");

        for (uint256 i = startIndex; i < endIndex; i++) {
            address gauge = voter.getGauge(i);
            try voter.distribute(gauge) {
                successCount++;
                emit DistributionSuccess(gauge);
            } catch (bytes memory reason) {
                failureCount++;
                emit DistributionFailure(gauge, reason);
            }
        }
    }

    /**
     * @notice Batch distribute rewards to specific gauges
     * @param _gauges Array of gauge addresses to distribute to
     * @return successCount Number of successful distributions
     * @return failureCount Number of failed distributions
     */
    function batchDistribute(address[] calldata _gauges)
        external
        returns (uint256 successCount, uint256 failureCount)
    {
        for (uint256 i = 0; i < _gauges.length; i++) {
            try voter.distribute(_gauges[i]) {
                successCount++;
                emit DistributionSuccess(_gauges[i]);
            } catch (bytes memory reason) {
                failureCount++;
                emit DistributionFailure(_gauges[i], reason);
            }
        }
    }
}

