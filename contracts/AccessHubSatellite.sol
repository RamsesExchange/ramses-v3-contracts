// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessHub} from "./interfaces/IAccessHub.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IVoter} from "./interfaces/IVoter.sol";
import {IMinter} from "./interfaces/IMinter.sol";
import {IXRam} from "./interfaces/IXRam.sol";
import {IR33} from "./interfaces/IR33.sol";
import {IFeeRecipient} from "./interfaces/IFeeRecipient.sol";

import {IRamsesV3Factory} from "./CL/core/interfaces/IRamsesV3Factory.sol";
import {IPairFactory} from "./interfaces/IPairFactory.sol";
import {IFeeRecipientFactory} from "./interfaces/IFeeRecipientFactory.sol";
import {IRamsesV3Pool} from "./CL/core/interfaces/IRamsesV3Pool.sol";
import {IFeeCollector} from "./CL/gauge/interfaces/IFeeCollector.sol";
import {IGaugeV3} from "./CL/gauge/interfaces/IGaugeV3.sol";
import {IRewardValidator} from "./CL/gauge/interfaces/IRewardValidator.sol";
import {IVoteModule} from "./interfaces/IVoteModule.sol";
import {GaugeV3} from "./CL/gauge/GaugeV3.sol";
import {ClGaugeFactory} from "./CL/gauge/ClGaugeFactory.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {INonfungiblePositionManager} from "./CL/periphery/interfaces/INonfungiblePositionManager.sol";

import {Errors} from "./libraries/Errors.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPair} from "./interfaces/IPair.sol";
import {IAutoVault} from "./autovault/interfaces/IAutoVault.sol";
import {AccessHubExtension} from "./libraries/AccessHubExtension.sol";

interface IPharaohMinter {
    function adjustEmissions(int256 _basisPointsChange) external;
}

interface IPharaohAutoVault {
    function setLegacyRouter(address legacyRouter) external;
}

/// @notice Shared AccessHub implementation for satellite deployments.
/// @dev Retains the deployed Pharaoh storage layout and callable surface for upgrade compatibility.
contract AccessHubSatellite is IAccessHub, Initializable, AccessControlEnumerableUpgradeable {
    /**
     * Start of Storage Slots
     */
    /// @notice role that can call changing fee splits and swap fees
    bytes32 public constant SWAP_FEE_SETTER = keccak256("SWAP_FEE_SETTER");
    /// @notice operator role
    bytes32 public constant PROTOCOL_OPERATOR = keccak256("PROTOCOL_OPERATOR");

    /// @inheritdoc IAccessHub
    address public timelock;
    /// @inheritdoc IAccessHub
    address public treasury;

    /**
     * "nice-to-have" addresses for quickly finding contracts within the system
     */

    /// @inheritdoc IAccessHub
    address public clGaugeFactory;
    /// @inheritdoc IAccessHub
    address public gaugeFactory;
    /// @inheritdoc IAccessHub
    address public feeDistributorFactory;

    /**
     * core contracts
     */

    /// @notice central voter contract
    IVoter public voter;
    /// @notice weekly emissions minter
    IMinter public minter;

    /// @notice xRam contract
    IXRam public xRam;
    /// @notice R33 contract
    IR33 public r33;
    /// @notice CL V3 factory
    IRamsesV3Factory public ramsesV3PoolFactory;
    /// @notice legacy pair factory
    IPairFactory public poolFactory;
    /// @notice legacy fees holder contract
    IFeeRecipientFactory public feeRecipientFactory;
    /// @notice fee collector contract
    IFeeCollector public feeCollector;
    /// @notice voteModule contract
    IVoteModule public voteModule;
    /// @notice nonFungiblePositionManager contract
    INonfungiblePositionManager public nfpManager;
    /// @notice AutoVault contract
    IAutoVault public autoVault;

    /**
     * End of Storage Slots
     */
    modifier timelocked() {
        require(msg.sender == timelock, NOT_TIMELOCK(msg.sender));
        _;
    }
    modifier onlyMultisig() {
        require(msg.sender == treasury, Errors.NOT_AUTHORIZED(msg.sender));
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IAccessHub
    function initialize(InitParams calldata params) external initializer {
        /// @dev initialize all external interfaces
        timelock = params.timelock;
        treasury = params.treasury;
        voter = IVoter(params.voter);
        minter = IMinter(params.minter);
        xRam = IXRam(params.xRam);
        r33 = IR33(params.r33);
        ramsesV3PoolFactory = IRamsesV3Factory(params.ramsesV3PoolFactory);
        poolFactory = IPairFactory(params.poolFactory);
        feeRecipientFactory = IFeeRecipientFactory(params.feeRecipientFactory);
        feeCollector = IFeeCollector(params.feeCollector);
        voteModule = IVoteModule(params.voteModule);
        /// @dev reference addresses
        clGaugeFactory = params.clGaugeFactory;
        gaugeFactory = params.gaugeFactory;
        feeDistributorFactory = params.feeDistributorFactory;

        /// @dev fee setter role given to treasury
        _grantRole(SWAP_FEE_SETTER, params.treasury);
        /// @dev operator role given to treasury
        _grantRole(PROTOCOL_OPERATOR, params.treasury);
        /// @dev initially give admin role to treasury
        _grantRole(DEFAULT_ADMIN_ROLE, params.treasury);
        /// @dev give timelock the admin role
        _grantRole(DEFAULT_ADMIN_ROLE, params.timelock);
    }

    function reinit(InitParams calldata params) external onlyMultisig {
        voter = IVoter(params.voter);
        minter = IMinter(params.minter);
        xRam = IXRam(params.xRam);
        r33 = IR33(params.r33);
        ramsesV3PoolFactory = IRamsesV3Factory(params.ramsesV3PoolFactory);
        poolFactory = IPairFactory(params.poolFactory);
        feeRecipientFactory = IFeeRecipientFactory(params.feeRecipientFactory);
        feeCollector = IFeeCollector(params.feeCollector);
        voteModule = IVoteModule(params.voteModule);
        /// @dev reference addresses
        clGaugeFactory = params.clGaugeFactory;
        gaugeFactory = params.gaugeFactory;
        feeDistributorFactory = params.feeDistributorFactory;
    }

    /// @inheritdoc IAccessHub
    function initializeVoter(IVoter.InitializationParams memory inputs) external onlyMultisig {
        voter.initialize(inputs);
    }

    /**
     * Fee Setting Logic
     */

    /// @inheritdoc IAccessHub
    function setSwapFees(address[] calldata _pools, uint24[] calldata _swapFees) external onlyRole(SWAP_FEE_SETTER) {
        /// @dev ensure continuity of length
        require(_pools.length == _swapFees.length, Errors.LENGTH_MISMATCH());
        for (uint256 i; i < _pools.length; ++i) {
            /// @dev we check if the pool is v3 or legacy and set their fees accordingly
            if (ramsesV3PoolFactory.isPairV3(_pools[i])) {
                ramsesV3PoolFactory.setFee(_pools[i], _swapFees[i]);
            } else if (poolFactory.isPair(_pools[i])) {
                poolFactory.setPairFee(_pools[i], _swapFees[i]);
            }
        }
    }

    /// @inheritdoc IAccessHub
    function setFeeSplitCL(address[] calldata _pools, uint24[] calldata _feeProtocol) external {
        /// @dev allow either SWAP_FEE_SETTER role holders OR the voter contract
        require(hasRole(SWAP_FEE_SETTER, msg.sender) || msg.sender == address(voter), Errors.NOT_AUTHORIZED(msg.sender));

        /// @dev ensure continuity of length
        require(_pools.length == _feeProtocol.length, Errors.LENGTH_MISMATCH());
        for (uint256 i; i < _pools.length; ++i) {
            ramsesV3PoolFactory.setPoolFeeProtocol(_pools[i], _feeProtocol[i]);
        }
    }

    /// @inheritdoc IAccessHub
    function setFeeSplitLegacy(address[] calldata _pools, uint256[] calldata _feeSplits) external {
        /// @dev allow either SWAP_FEE_SETTER role holders OR the voter contract
        require(hasRole(SWAP_FEE_SETTER, msg.sender) || msg.sender == address(voter), Errors.NOT_AUTHORIZED(msg.sender));

        /// @dev ensure continuity of length
        require(_pools.length == _feeSplits.length, Errors.LENGTH_MISMATCH());
        for (uint256 i; i < _pools.length; ++i) {
            poolFactory.setPairFeeSplit(_pools[i], _feeSplits[i]);
        }
    }

    /// @notice sets the fee recipient for legacy pairs
    function setFeeRecipientLegacyBatched(address[] calldata _pairs, address[] calldata _feeRecipients)
        external
        onlyMultisig
    {
        require(_pairs.length == _feeRecipients.length, Errors.LENGTH_MISMATCH());
        for (uint256 i; i < _pairs.length; ++i) {
            poolFactory.setFeeRecipient(_pairs[i], _feeRecipients[i]);
        }
    }

    /**
     * Voter governance
     */

    /// @inheritdoc IAccessHub
    function setNewGovernorInVoter(address _newGovernor) external onlyRole(PROTOCOL_OPERATOR) {
        /// @dev no checks are needed as the voter handles this already
        voter.setGovernor(_newGovernor);
    }

    /// @inheritdoc IAccessHub
    function governanceWhitelist(address[] calldata _token, bool[] calldata _whitelisted)
        external
        onlyRole(PROTOCOL_OPERATOR)
    {
        /// @dev ensure continuity of length
        require(_token.length == _whitelisted.length, Errors.LENGTH_MISMATCH());
        for (uint256 i; i < _token.length; ++i) {
            /// @dev if adding to the whitelist
            if (_whitelisted[i]) {
                /// @dev call the voter's whitelist function
                voter.whitelist(_token[i]);
            }
            /// @dev remove the token's whitelist
            else {
                voter.revokeWhitelist(_token[i]);
            }
        }
    }

    /// @inheritdoc IAccessHub
    function killGauge(address[] calldata _pairs) external onlyRole(PROTOCOL_OPERATOR) {
        for (uint256 i; i < _pairs.length; ++i) {
            /// @dev store pair
            address pair = _pairs[i];
            address gauge = voter.gaugeForPool(pair);
            /// @dev collect fees based on pool type
            if (voter.isDLMMRewarder(gauge)) {
                AccessHubExtension.collectFees(voter, pair);
            } else if (ramsesV3PoolFactory.isPairV3(pair)) {
                // V3 pool: collect protocol fees
                feeCollector.collectProtocolFees(pair);
            } else if (poolFactory.isPair(pair)) {
                // Legacy pool: mint fees and notify
                IPair(pair).mintFee();
                address feeRecipient = IPair(pair).feeRecipient();
                if (feeRecipient != address(0)) {
                    IFeeRecipient(feeRecipient).notifyFees();
                }
            }
            /// @dev kill the gauge
            voter.killGauge(gauge);
            // voter will handle the fee split on epoch flip
        }
    }

    /// @inheritdoc IAccessHub
    function reviveGauge(address[] calldata _pairs) external onlyRole(PROTOCOL_OPERATOR) {
        for (uint256 i; i < _pairs.length; ++i) {
            address pair = _pairs[i];
            address gauge = voter.gaugeForPool(pair);
            /// @dev collect fees based on pool type
            if (voter.isDLMMRewarder(gauge)) {
                AccessHubExtension.collectFees(voter, pair);
            } else if (ramsesV3PoolFactory.isPairV3(pair)) {
                // V3 pool: collect protocol fees
                feeCollector.collectProtocolFees(pair);
            } else if (poolFactory.isPair(pair)) {
                // Legacy pool: mint fees and notify
                IPair(pair).mintFee();
                address feeRecipient = IPair(pair).feeRecipient();
                if (feeRecipient != address(0)) {
                    IFeeRecipient(feeRecipient).notifyFees();
                }
            }
            /// @dev revive the pair
            voter.reviveGauge(gauge);
            /// @dev set fee to the factory default only for V3 pools
            if (ramsesV3PoolFactory.isPairV3(pair)) {
                ramsesV3PoolFactory.setPoolFeeProtocol(pair, ramsesV3PoolFactory.feeProtocol());
            }
        }
    }

    /// @inheritdoc IAccessHub
    function setEmissionsRatioInVoter(uint256 _pct) external onlyRole(PROTOCOL_OPERATOR) {
        voter.setGlobalRatio(_pct);
    }

    /// @inheritdoc IAccessHub
    function retrieveStuckEmissionsToGovernance(address _gauge, uint256 _period) external onlyRole(PROTOCOL_OPERATOR) {
        voter.stuckEmissionsRecovery(_gauge, _period);
    }

    /// @notice Set the minimum time threshold for rewarder (in seconds)
    /// @param _timeThreshold New time threshold in seconds (0 = no threshold)
    function setTimeThresholdForRewarder(uint256 _timeThreshold) external onlyRole(PROTOCOL_OPERATOR) {
        voter.setTimeThresholdForRewarder(_timeThreshold);
    }

    /// @inheritdoc IAccessHub
    function createLegacyGauge(address _pool) external onlyRole(PROTOCOL_OPERATOR) returns (address) {
        return voter.createGauge(_pool);
    }

    function createCLGauge(address tokenA, address tokenB, int24 tickSpacing)
        external
        onlyRole(PROTOCOL_OPERATOR)
        returns (address)
    {
        return _createCLGauge(tokenA, tokenB, tickSpacing, false);
    }

    /// @inheritdoc IAccessHub
    function createCLGauge(address tokenA, address tokenB, int24 tickSpacing, bool forceVoterFees)
        external
        onlyRole(PROTOCOL_OPERATOR)
        returns (address)
    {
        return _createCLGauge(tokenA, tokenB, tickSpacing, forceVoterFees);
    }

    function _createCLGauge(address tokenA, address tokenB, int24 tickSpacing, bool forceVoterFees)
        internal
        returns (address)
    {
        address gauge = voter.createCLGauge(tokenA, tokenB, tickSpacing);

        if (forceVoterFees) {
            address pool = voter.poolForGauge(gauge);
            ramsesV3PoolFactory.setPoolFeeProtocol(pool, 1_000_000);
        }

        return gauge;
    }

    /// @inheritdoc IAccessHub
    function setDLMMFactoryInVoter(address newDLMMFactory) external onlyMultisig {
        voter.setDLMMFactory(newDLMMFactory);
    }

    /// @inheritdoc IAccessHub
    function setDLMMRewarderFactoryInVoter(address newDLMMRewarderFactory) public onlyMultisig {
        voter.setDLMMRewarderFactory(newDLMMRewarderFactory);
    }

    /// @inheritdoc IAccessHub
    function setDLMMRewarderFactoryImpl(address newImplementation) external onlyMultisig {
        AccessHubExtension.setRewarderFactoryImplementation(voter, newImplementation);
    }

    /// @inheritdoc IAccessHub
    function setDLMMHooksManager(address manager, bool enabled) external onlyMultisig {
        AccessHubExtension.setHooksManager(voter, manager, enabled);
    }

    /// @inheritdoc IAccessHub
    function acceptDLMMFactoryOwnership() external onlyMultisig {
        AccessHubExtension.acceptFactoryOwnership(voter);
    }

    /// @inheritdoc IAccessHub
    function createDLMMPool(address tokenX, address tokenY, uint24 activeId, uint16 binStep)
        external
        onlyRole(PROTOCOL_OPERATOR)
        returns (address pool)
    {
        pool = AccessHubExtension.createPool(voter, tokenX, tokenY, activeId, binStep);
    }

    /// @inheritdoc IAccessHub
    function createDLMMRewarder(address pool) external onlyRole(PROTOCOL_OPERATOR) returns (address rewarder) {
        rewarder = voter.createDLMMRewarder(pool);
    }

    /// @inheritdoc IAccessHub
    function setDLMMRewarderDeltaBins(address _rewarder, int24 _deltaBinA, int24 _deltaBinB) external onlyMultisig {
        voter.setDLMMRewarderDeltaBins(_rewarder, _deltaBinA, _deltaBinB);
    }

    /// @inheritdoc IAccessHub
    function setTreasuryInDLMMFeeCollector(address newTreasury) external onlyRole(PROTOCOL_OPERATOR) {
        AccessHubExtension.setTreasury(voter, newTreasury);
    }

    /// @inheritdoc IAccessHub
    function setTreasuryFeesInDLMMFeeCollector(uint256 _treasuryFees) external onlyRole(PROTOCOL_OPERATOR) {
        AccessHubExtension.setTreasuryFees(voter, _treasuryFees);
    }

    /// @inheritdoc IAccessHub
    function setVoterInDLMMFeeCollector(address _voter) external onlyMultisig {
        AccessHubExtension.setVoter(voter, _voter);
    }

    /// @inheritdoc IAccessHub
    function setFeeSplitDLMM(address[] calldata _pools, uint16[] calldata _protocolShares) external {
        if (msg.sender != address(voter)) _checkRole(SWAP_FEE_SETTER);
        AccessHubExtension.setFeeSplit(voter, _pools, _protocolShares);
    }

    function setSwapFeeParametersDLMM(address[] calldata _pools, bytes32[] calldata _feeParameters) external {
        _checkRole(SWAP_FEE_SETTER);
        AccessHubExtension.setSwapFeeParameters(voter, _pools, _feeParameters);
    }

    /// @inheritdoc IAccessHub
    function setGlobalDLMMFeeSplit(uint16 binStep, uint16 protocolShare) external onlyMultisig {
        AccessHubExtension.setGlobalFeeSplit(voter, binStep, protocolShare);
    }

    /// @notice Opens or closes a DLMM bin-step preset for permissionless pool creation.
    function setDLMMPresetOpenState(uint16 binStep, bool isOpen) external onlyMultisig {
        AccessHubExtension.setDLMMPresetOpenState(voter, binStep, isOpen);
    }

    /**
     * xRam Functions
     */

    function setFeeCollectorAccessHub(address _feeCollector) external onlyMultisig {
        feeCollector = IFeeCollector(_feeCollector);
    }

    function setFeeCollectorInClGaugeFactory(address _feeCollector) external onlyMultisig {
        ClGaugeFactory(clGaugeFactory).setFeeCollector(_feeCollector);
    }

    /// @inheritdoc IAccessHub
    function transferWhitelistInXRam(address[] calldata _who, bool[] calldata _whitelisted)
        external
        onlyRole(PROTOCOL_OPERATOR)
    {
        AccessHubExtension.transferWhitelistInXRam(xRam, _who, _whitelisted);
    }

    /// @inheritdoc IAccessHub
    function transferToWhitelistInXRam(address[] calldata _who, bool[] calldata _whitelisted)
        external
        onlyRole(PROTOCOL_OPERATOR)
    {
        AccessHubExtension.transferToWhitelistInXRam(xRam, _who, _whitelisted);
    }

    /// @inheritdoc IAccessHub
    function transferOperatorInXRam(address _operator) external onlyRole(PROTOCOL_OPERATOR) {
        AccessHubExtension.transferOperatorInXRam(xRam, _operator);
    }

    /**
     * R33 Functions
     */

    function rescueR33Token(address _token) external onlyMultisig {
        AccessHubExtension.rescueR33Token(r33, treasury, _token);
    }

    /// @inheritdoc IAccessHub
    function transferOperatorInR33(address _newOperator) external onlyRole(PROTOCOL_OPERATOR) {
        r33.transferOperator(_newOperator);
    }

    // @inheritdoc IAccessHub
    function compoundR33() external onlyRole(SWAP_FEE_SETTER) {
        AccessHubExtension.compoundR33(xRam, r33);
    }

    function unwrapR33LegacyIncentives(address _lpToken) external onlyRole(SWAP_FEE_SETTER) {
        AccessHubExtension.unwrapR33LegacyIncentives(r33, poolFactory, _lpToken);
    }

    function whitelistAggregatorInR33(address _aggregator, bool _status) external onlyMultisig {
        r33.whitelistAggregator(_aggregator, _status);
    }

    /**
     * Minter Functions
     */
    /// @notice Update emissions multiplier
    /// @param _newMultiplier The new emissions multiplier
    /// @inheritdoc IAccessHub
    function updateEmissionsMultiplierInMinter(uint256 _newMultiplier) external onlyRole(PROTOCOL_OPERATOR) {
        uint256 currentMultiplier = minter.emissionsMultiplier();
        require(currentMultiplier != 0, Errors.ZERO());
        require(_newMultiplier != 0, Errors.ZERO());

        uint256 scaledTarget = _newMultiplier * 10_000;
        require(scaledTarget % currentMultiplier == 0, Errors.NO_CHANGE());

        int256 basisPointsChange = int256(scaledTarget / currentMultiplier) - 10_000;
        IPharaohMinter(address(minter)).adjustEmissions(basisPointsChange);

        require(minter.emissionsMultiplier() == _newMultiplier, Errors.NO_CHANGE());
    }

    function adjustEmissionsInMinter(int256 _basisPointsChange) external onlyRole(PROTOCOL_OPERATOR) {
        IPharaohMinter(address(minter)).adjustEmissions(_basisPointsChange);
    }

    /// @inheritdoc IAccessHub
    function removeFeeDistributorRewards(address[] calldata _pools, address[] calldata _rewards)
        external
        onlyRole(PROTOCOL_OPERATOR)
    {
        require(_pools.length == _rewards.length, Errors.LENGTH_MISMATCH());
        for (uint256 i; i < _pools.length; ++i) {
            voter.removeFeeDistributorReward(voter.feeDistributorForGauge(voter.gaugeForPool(_pools[i])), _rewards[i]);
        }
    }

    /**
     * FeeCollector functions
     */

    /// @inheritdoc IAccessHub
    function setTreasuryInFeeCollector(address newTreasury) external onlyRole(PROTOCOL_OPERATOR) {
        feeCollector.setTreasury(newTreasury);
    }

    /// @inheritdoc IAccessHub
    function setTreasuryFeesInFeeCollector(uint256 _treasuryFees) external onlyRole(PROTOCOL_OPERATOR) {
        feeCollector.setTreasuryFees(_treasuryFees);
    }

    /**
     * FeeRecipientFactory functions
     */

    /// @inheritdoc IAccessHub
    function setFeeToTreasuryInFeeRecipientFactory(uint256 _feeToTreasury) external onlyRole(PROTOCOL_OPERATOR) {
        feeRecipientFactory.setFeeToTreasury(_feeToTreasury);
    }

    /// @inheritdoc IAccessHub
    function setTreasuryInFeeRecipientFactory(address _treasury) external onlyRole(PROTOCOL_OPERATOR) {
        feeRecipientFactory.setTreasury(_treasury);
    }

    /**
     * CL Pool Factory functions
     */

    /// @inheritdoc IAccessHub
    function enableTickSpacing(int24 tickSpacing, uint24 initialFee) external onlyRole(PROTOCOL_OPERATOR) {
        ramsesV3PoolFactory.enableTickSpacing(tickSpacing, initialFee);
    }

    /// @inheritdoc IAccessHub
    function setGlobalClFeeProtocol(uint24 _feeProtocolGlobal) external onlyRole(PROTOCOL_OPERATOR) {
        ramsesV3PoolFactory.setFeeProtocol(_feeProtocolGlobal);
    }

    /// @inheritdoc IAccessHub
    /// @notice sets the address of the voter in the v3 factory for gauge fee setting
    function setVoterAddressInFactoryV3(address _voter) external onlyMultisig {
        ramsesV3PoolFactory.setVoter(_voter);
    }

    /// @inheritdoc IAccessHub
    /// @notice sets the address of the voter in the fee recipient factory for fee recipient creation
    function setVoterInFeeRecipientFactory(address _voter) external onlyMultisig {
        feeRecipientFactory.setVoter(_voter);
    }

    /// @inheritdoc IAccessHub
    function setFeeCollectorInFactoryV3(address _newFeeCollector) external onlyMultisig {
        ramsesV3PoolFactory.setFeeCollector(_newFeeCollector);
    }

    /// @notice Update FeeDistributor for a gauge (emergency governance function)
    function updateFeeDistributorForGauge(address _gauge, address _newFeeDistributor) external onlyMultisig {
        voter.updateFeeDistributorForGauge(_gauge, _newFeeDistributor);
    }

    /// @notice Create a new FeeDistributor with specified feeRecipient (emergency governance function)
    function createFeeDistributorWithRecipient(address _feeRecipient) external onlyMultisig returns (address) {
        return voter.createFeeDistributorWithRecipient(_feeRecipient);
    }

    /**
     * Legacy Pool Factory functions
     */

    /// @inheritdoc IAccessHub
    function setTreasuryInLegacyFactory(address _treasury) external onlyMultisig {
        poolFactory.setTreasury(_treasury);
    }

    /// @inheritdoc IAccessHub
    function setVoterInLegacyFactory(address _voter) external onlyMultisig {
        IPairFactory(poolFactory).setVoter(_voter);
    }

    /// @inheritdoc IAccessHub
    function setFeeSplitWhenNoGauge(bool status) external onlyRole(PROTOCOL_OPERATOR) {
        poolFactory.setFeeSplitWhenNoGauge(status);
    }

    /// @inheritdoc IAccessHub
    function setLegacyFeeSplitGlobal(uint256 _feeSplit) external onlyRole(PROTOCOL_OPERATOR) {
        poolFactory.setFeeSplit(_feeSplit);
    }

    /// @inheritdoc IAccessHub
    function setLegacyFeeGlobal(uint256 _fee) external onlyRole(PROTOCOL_OPERATOR) {
        poolFactory.setFee(_fee);
    }

    /// @inheritdoc IAccessHub
    function setSkimEnabledLegacy(address _pair, bool _status) external onlyRole(PROTOCOL_OPERATOR) {
        poolFactory.setSkimEnabled(_pair, _status);
    }

    /**
     * VoteModule Functions
     */

    /// @inheritdoc IAccessHub
    function setCooldownExemption(address[] calldata _candidates, bool[] calldata _exempt) external onlyMultisig {
        for (uint256 i; i < _candidates.length; ++i) {
            voteModule.setCooldownExemption(_candidates[i], _exempt[i]);
        }
    }

    /// @inheritdoc IAccessHub
    function setNewVoteModuleCooldown(uint256 _newCooldown) external timelocked {
        voteModule.setNewCooldown(_newCooldown);
    }

    /**
     * Timelock specific functions
     */

    /// @inheritdoc IAccessHub
    function execute(address _target, bytes calldata _payload) external timelocked {
        (bool success,) = _target.call(_payload);
        require(success, MANUAL_EXECUTION_FAILURE(_payload));
    }

    /// @inheritdoc IAccessHub
    function setNewTimelock(address _timelock) external timelocked {
        require(timelock != _timelock, SAME_ADDRESS());
        timelock = _timelock;
    }

    function setClGaugeFactoryImpl(address _newImplementation) public onlyMultisig {
        ClGaugeFactory(clGaugeFactory).setImplementation(_newImplementation);
    }

    /// @notice toggle anti-sybil mechanism
    function toggleAntiSybil() external onlyMultisig {
        voter.toggleAntiSybil();
    }

    /// @notice set the reward validator contract
    /// @param _rewardValidator The address of the RewardValidator contract
    function setRewardValidator(address _rewardValidator) external onlyMultisig {
        voter.setRewardValidator(_rewardValidator);
    }

    /// @notice update the nfp manager in the reward validator
    /// @param _nfpManager The address of the new NfpManager contract
    function setRewardValidatorNfpManager(address _nfpManager) external onlyMultisig {
        address rewardValidator = voter.rewardValidator();
        require(rewardValidator != address(0), Errors.NOT_INIT());
        IRewardValidator(rewardValidator).setNfpManager(_nfpManager);
    }

    /// @notice set the nfp manager
    /// @param _nfpManager The address of the NfpManager contract
    function setNfpManager(address _nfpManager) external onlyMultisig {
        voter.setNfpManager(_nfpManager);
    }

    /// @notice clawback bribes/incentives from a FeeDistributor for the next period
    function clawbackIncentives(address _tokenToClawback, address _poolAddress) external onlyMultisig {
        address feeDistributor = voter.feeDistributorForGauge(voter.gaugeForPool(_poolAddress));
        IFeeDistributor(feeDistributor).clawbackRewards(_tokenToClawback, address(treasury));
    }

    function addAuthorizedClaimerVoter(address _claimer) external onlyMultisig {
        voter.addAuthorizedClaimer(_claimer);
    }

    function removeAuthorizedClaimerVoter(address _claimer) external onlyMultisig {
        voter.removeAuthorizedClaimer(_claimer);
    }

    function addAuthorizedDLMMManagerVoter(address _manager) external onlyMultisig {
        voter.addAuthorizedDLMMManager(_manager);
    }

    function removeAuthorizedDLMMManagerVoter(address _manager) external onlyMultisig {
        voter.removeAuthorizedDLMMManager(_manager);
    }

    /// @inheritdoc IAccessHub
    function addRewardsToGauge(address _gauge, address _reward) external onlyRole(PROTOCOL_OPERATOR) {
        IGaugeV3(_gauge).addRewards(_reward);
    }

    /// @inheritdoc IAccessHub
    function removeRewardsFromGauge(address _gauge, address _reward) external onlyRole(PROTOCOL_OPERATOR) {
        IGaugeV3(_gauge).removeRewards(_reward);
    }

    /// @inheritdoc IAccessHub
    function batchAddRewardsToGauges(address[] calldata _gauges, address[] calldata _rewards)
        external
        onlyRole(PROTOCOL_OPERATOR)
    {
        require(_gauges.length == _rewards.length, Errors.LENGTH_MISMATCH());
        for (uint256 i = 0; i < _gauges.length; i++) {
            IGaugeV3(_gauges[i]).addRewards(_rewards[i]);
        }
    }

    /// @inheritdoc IAccessHub
    function batchRemoveRewardsFromGauges(address[] calldata _gauges, address[] calldata _rewards)
        external
        onlyRole(PROTOCOL_OPERATOR)
    {
        require(_gauges.length == _rewards.length, Errors.LENGTH_MISMATCH());
        for (uint256 i = 0; i < _gauges.length; i++) {
            IGaugeV3(_gauges[i]).removeRewards(_rewards[i]);
        }
    }

    function addRewardToAllGauges(address _reward) external onlyRole(PROTOCOL_OPERATOR) {
        AccessHubExtension.addRewardToAllClGauges(voter, _reward);
    }

    function removeRewardFromAllGauges(address _reward) external onlyRole(PROTOCOL_OPERATOR) {
        AccessHubExtension.removeRewardFromAllClGauges(voter, _reward);
    }

    function syncClGaugesBatch(uint256 startIndex, uint256 endIndex) external onlyMultisig {
        address[] memory allGauges = voter.getAllGauges();
        uint256 gaugesLength = allGauges.length;

        if (endIndex == 0 || endIndex > gaugesLength) {
            endIndex = gaugesLength;
        }

        require(startIndex < endIndex, Errors.NO_CHANGE());

        for (uint256 i = startIndex; i < endIndex; i++) {
            if (voter.isClGauge(allGauges[i])) {
                try IGaugeV3(allGauges[i]).syncCache() {} catch {}
            }
        }
    }

    /**
     * AutoVault Functions
     */

    /// @inheritdoc IAccessHub
    function setAutoVault(address _autoVault) external onlyMultisig {
        autoVault = IAutoVault(_autoVault);
    }

    /// @inheritdoc IAccessHub
    function addOutputTokenAutoVault(address _token) external onlyMultisig {
        autoVault.addOutputToken(_token);
    }

    /// @inheritdoc IAccessHub
    function removeOutputTokenAutoVault(address _token, bool _force) external onlyMultisig {
        autoVault.removeOutputToken(_token, _force);
    }

    /// @inheritdoc IAccessHub
    function addAggregatorAutoVault(address _aggregator) external onlyMultisig {
        autoVault.addAggregator(_aggregator);
    }

    /// @inheritdoc IAccessHub
    function removeAggregatorAutoVault(address _aggregator) external onlyMultisig {
        autoVault.removeAggregator(_aggregator);
    }

    /// @inheritdoc IAccessHub
    function setOperatorAutoVault(address _operator) external onlyMultisig {
        autoVault.setOperator(_operator);
    }

    /// @inheritdoc IAccessHub
    function rescueAutoVault(address _token, uint256 _amount) external onlyMultisig {
        AccessHubExtension.rescueAutoVault(autoVault, treasury, _token, _amount);
    }

    function setLegacyRouterAutoVault(address _legacyRouter) external onlyMultisig {
        IPharaohAutoVault(address(autoVault)).setLegacyRouter(_legacyRouter);
    }
}
