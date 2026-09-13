// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VoterStorage} from "contracts/libraries/VoterStorage.sol";

import {IAccessHub} from "contracts/interfaces/IAccessHub.sol";
import {IFeeRecipient} from "contracts/interfaces/IFeeRecipient.sol";
import {IFeeRecipientFactory} from "contracts/interfaces/IFeeRecipientFactory.sol";
import {IPair} from "contracts/interfaces/IPair.sol";
import {IRamsesV3Factory} from "contracts/CL/core/interfaces/IRamsesV3Factory.sol";
import {IFeeCollector} from "contracts/CL/gauge/interfaces/IFeeCollector.sol";
import {VoterDLMMActions} from "contracts/libraries/VoterDLMMActions.sol";

library VoterFeeSyncActions {
    function syncFeeSplitAndCollectFees(address gauge, address pool, uint256 basis) external {
        VoterStorage.VoterState storage $ = VoterStorage.getStorage();

        if ($.isClGauge[gauge]) {
            if ($.voterOwnsFactory) {
                uint24 currentSplit = IRamsesV3Factory($.clFactory).poolFeeProtocol(pool);
                if (
                    currentSplit == 1_000_000 || currentSplit == 50_000
                        || currentSplit == IRamsesV3Factory($.clFactory).feeProtocol()
                ) {
                    if ($.isAlive[gauge]) {
                        IRamsesV3Factory($.clFactory).gaugeFeeSplitEnable(pool);
                    } else {
                        address[] memory pools = new address[](1);
                        pools[0] = pool;
                        uint24[] memory feeProtocols = new uint24[](1);
                        feeProtocols[0] = 50_000;
                        IAccessHub($.accessHub).setFeeSplitCL(pools, feeProtocols);
                    }
                }
            }

            try IFeeCollector(IRamsesV3Factory($.clFactory).feeCollector()).collectProtocolFees(pool) {} catch {}
        } else if ($.isDLMMRewarder[gauge]) {
            VoterDLMMActions.collectFees(gauge, pool);
        } else if ($.isLegacyGauge[gauge]) {
            address[] memory pools = new address[](1);
            uint256[] memory feeSplits = new uint256[](1);
            pools[0] = pool;

            if ($.isAlive[gauge]) {
                feeSplits[0] = basis;
            } else {
                feeSplits[0] = basis / 20;
            }

            IAccessHub($.accessHub).setFeeSplitLegacy(pools, feeSplits);

            IPair(pool).mintFee();
            IFeeRecipient(IFeeRecipientFactory($.feeRecipientFactory).feeRecipientForPair(pool)).notifyFees();
        }
    }
}
