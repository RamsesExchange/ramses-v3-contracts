// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Constants} from "../libraries/Constants.sol";
import {PriceHelper} from "../libraries/PriceHelper.sol";
import {SafeCast} from "../libraries/math/SafeCast.sol";
import {Uint256x256Math} from "../libraries/math/Uint256x256Math.sol";

import {IDLMMFactory} from "../interfaces/IDLMMFactory.sol";
import {IDLMMRouter} from "../interfaces/IDLMMRouter.sol";

contract DLMMQuoter {
    using SafeCast for uint256;
    using Uint256x256Math for uint256;

    error DLMMQuoter__InvalidLength();

    IDLMMFactory private immutable _factory;

    struct Quote {
        address[] route;
        address[] pairs;
        uint256[] binSteps;
        IDLMMRouter.Version[] versions;
        uint128[] amounts;
        uint128[] virtualAmountsWithoutSlippage;
        uint128[] fees;
    }

    constructor(IDLMMFactory factory) {
        _factory = factory;
    }

    function getFactory() external view returns (IDLMMFactory factory) {
        factory = _factory;
    }

    function findBestPathFromAmountIn(address[] calldata route, uint128 amountIn)
        external
        view
        returns (Quote memory quote)
    {
        if (route.length < 2) revert DLMMQuoter__InvalidLength();

        quote.route = route;

        uint256 swapLength = route.length - 1;
        quote.pairs = new address[](swapLength);
        quote.binSteps = new uint256[](swapLength);
        quote.versions = new IDLMMRouter.Version[](swapLength);
        quote.fees = new uint128[](swapLength);
        quote.amounts = new uint128[](route.length);
        quote.virtualAmountsWithoutSlippage = new uint128[](route.length);

        quote.amounts[0] = amountIn;
        quote.virtualAmountsWithoutSlippage[0] = amountIn;

        for (uint256 i; i < swapLength; ++i) {
            IDLMMFactory.LBPairInformation[] memory pairs =
                _factory.getAllLBPairs(IERC20(route[i]), IERC20(route[i + 1]));

            if (pairs.length == 0 || quote.amounts[i] == 0) continue;

            for (uint256 j; j < pairs.length; ++j) {
                if (pairs[j].ignoredForRouting) continue;

                bool swapForY = address(pairs[j].LBPair.getTokenY()) == route[i + 1];

                try pairs[j].LBPair.getSwapOut(quote.amounts[i], swapForY) returns (
                    uint128 amountInLeft, uint128 swapAmountOut, uint128 fees
                ) {
                    if (amountInLeft != 0 || swapAmountOut <= quote.amounts[i + 1]) continue;

                    quote.amounts[i + 1] = swapAmountOut;
                    quote.pairs[i] = address(pairs[j].LBPair);
                    quote.binSteps[i] = uint16(pairs[j].binStep);
                    quote.versions[i] = IDLMMRouter.Version.V2_1;

                    uint24 activeId = pairs[j].LBPair.getActiveId();
                    quote.virtualAmountsWithoutSlippage[i + 1] = _getDLMMQuote(
                        quote.virtualAmountsWithoutSlippage[i] - fees, activeId, quote.binSteps[i], swapForY
                    );

                    quote.fees[i] = ((uint256(fees) * 1e18) / quote.amounts[i]).safe128();
                } catch {}
            }
        }
    }

    function findBestPathFromAmountOut(address[] calldata route, uint128 amountOut)
        external
        view
        returns (Quote memory quote)
    {
        if (route.length < 2) revert DLMMQuoter__InvalidLength();

        quote.route = route;

        uint256 swapLength = route.length - 1;
        quote.pairs = new address[](swapLength);
        quote.binSteps = new uint256[](swapLength);
        quote.versions = new IDLMMRouter.Version[](swapLength);
        quote.amounts = new uint128[](route.length);
        quote.virtualAmountsWithoutSlippage = new uint128[](route.length);
        quote.fees = new uint128[](swapLength);

        quote.amounts[swapLength] = amountOut;
        quote.virtualAmountsWithoutSlippage[swapLength] = amountOut;

        for (uint256 i = swapLength; i > 0; --i) {
            IDLMMFactory.LBPairInformation[] memory pairs =
                _factory.getAllLBPairs(IERC20(route[i - 1]), IERC20(route[i]));

            if (pairs.length == 0 || quote.amounts[i] == 0) continue;

            for (uint256 j; j < pairs.length; ++j) {
                if (pairs[j].ignoredForRouting) continue;

                bool swapForY = address(pairs[j].LBPair.getTokenY()) == route[i];

                try pairs[j].LBPair.getSwapIn(quote.amounts[i], swapForY) returns (
                    uint128 swapAmountIn, uint128 amountOutLeft, uint128 fees
                ) {
                    if (
                        amountOutLeft != 0 || swapAmountIn == 0
                            || (swapAmountIn >= quote.amounts[i - 1] && quote.amounts[i - 1] != 0)
                    ) continue;

                    quote.amounts[i - 1] = swapAmountIn;
                    quote.pairs[i - 1] = address(pairs[j].LBPair);
                    quote.binSteps[i - 1] = uint16(pairs[j].binStep);
                    quote.versions[i - 1] = IDLMMRouter.Version.V2_1;

                    uint24 activeId = pairs[j].LBPair.getActiveId();
                    quote.virtualAmountsWithoutSlippage[i - 1] = _getDLMMQuote(
                        quote.virtualAmountsWithoutSlippage[i], activeId, quote.binSteps[i - 1], !swapForY
                    ) + fees;

                    quote.fees[i - 1] = ((uint256(fees) * 1e18) / quote.amounts[i - 1]).safe128();
                } catch {}
            }
        }
    }

    function _getDLMMQuote(uint256 amount, uint24 activeId, uint256 binStep, bool swapForY)
        internal
        pure
        returns (uint128 quote)
    {
        if (swapForY) {
            quote = PriceHelper.getPriceFromId(activeId, uint16(binStep))
                .mulShiftRoundDown(amount, Constants.SCALE_OFFSET).safe128();
        } else {
            quote = amount.shiftDivRoundDown(
                    Constants.SCALE_OFFSET, PriceHelper.getPriceFromId(activeId, uint16(binStep))
                ).safe128();
        }
    }
}
