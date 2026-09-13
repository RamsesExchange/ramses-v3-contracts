// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
pragma abicoder v2;

interface IVoter {
    event GaugeCreated(address indexed gauge, address creator, address feeDistributor, address indexed pool);

    event GaugeKilled(address indexed gauge);

    event GaugeRevived(address indexed gauge);

    event Voted(address indexed owner, uint256 weight, address indexed pool);

    event Abstained(address indexed owner, uint256 weight);

    event Deposit(address indexed lp, address indexed gauge, address indexed owner, uint256 amount);

    event Withdraw(address indexed lp, address indexed gauge, address indexed owner, uint256 amount);

    event NotifyReward(address indexed sender, address indexed reward, uint256 amount);

    event DistributeReward(address indexed sender, address indexed gauge, uint256 amount);

    event EmissionsRatio(address indexed caller, uint256 oldRatio, uint256 newRatio);

    event NewGovernor(address indexed sender, address indexed governor);

    event Whitelisted(address indexed whitelister, address indexed token);

    event WhitelistRevoked(address indexed forbidder, address indexed token);

    event Poke(address indexed user);

    event EmissionsRedirected(address indexed sourceGauge, address indexed destinationGauge);

    event DistributionFailed(address indexed gauge, address indexed pool);

    event DLMMFactoryChanged(address indexed oldFactory, address indexed newFactory);
    event DLMMRewarderFactoryChanged(address indexed oldFactory, address indexed newFactory);

    event DLMMRewarderSet(address indexed rewarder, bool enabled);
    event AuthorizedDLMMManagerAdded(address indexed manager);
    event AuthorizedDLMMManagerRemoved(address indexed manager);

    struct InitializationParams {
        address ram;
        address legacyFactory;
        address gauges;
        address feeDistributorFactory;
        address minter;
        address msig;
        address xRam;
        address clFactory;
        address clGaugeFactory;
        address nfpManager;
        address feeRecipientFactory;
        address voteModule;
    }

    /// @notice Completes phase-two initialization and activates the dependencies required by the full protocol
    function initialize(InitializationParams memory inputs) external;

    /// @notice denominator basis
    function BASIS() external view returns (uint256);

    /// @notice ratio of xRam emissions globally
    function xRatio() external view returns (uint256);

    /// @notice minimum time threshold for rewarder (in seconds)
    function timeThresholdForRewarder() external view returns (uint256);

    /// @notice reward validator contract for anti-sybil validation
    function rewardValidator() external view returns (address);

    /// @notice toggle anti-sybil mechanism
    function toggleAntiSybil() external;

    /// @notice set the reward validator contract
    /// @param _rewardValidator The address of the RewardValidator contract
    function setRewardValidator(address _rewardValidator) external;

    /// @notice set the DLMM factory
    function setDLMMFactory(address _dlmmFactory) external;

    /// @notice set the DLMM rewarder factory
    function setDLMMRewarderFactory(address _dlmmRewarderFactory) external;

    /// @notice xRam contract address
    function xRam() external view returns (address);

    /// @notice legacy factory address (uni-v2/stableswap)
    function legacyFactory() external view returns (address);

    /// @notice concentrated liquidity factory
    function clFactory() external view returns (address);

    /// @notice DLMM factory address
    function dlmmFactory() external view returns (address);

    /// @notice DLMM rewarder factory address
    function dlmmRewarderFactory() external view returns (address);

    /// @notice gauge factory for CL
    function clGaugeFactory() external view returns (address);

    /// @notice legacy fee recipient factory
    function feeRecipientFactory() external view returns (address);

    /// @notice peripheral NFPManager contract
    function nfpManager() external view returns (address);

    /// @notice returns the address of the current governor
    /// @return _governor address of the governor
    function governor() external view returns (address _governor);

    /// @notice the address of the vote module
    /// @return _voteModule the vote module contract address
    function voteModule() external view returns (address _voteModule);

    /// @notice address of the central access Hub
    function accessHub() external view returns (address);

    /// @notice distributes emissions from the minter to the voter
    /// @param amount the amount of tokens to notify
    function notifyRewardAmount(uint256 amount) external;

    /// @notice distributes the emissions for a specific gauge
    /// @param _gauge the gauge address
    function distribute(address _gauge) external;

    /// @notice returns the address of the gauge factory
    /// @param _gaugeFactory gauge factory address
    function gaugeFactory() external view returns (address _gaugeFactory);

    /// @notice returns the address of the feeDistributor factory
    /// @return _feeDistributorFactory feeDist factory address
    function feeDistributorFactory() external view returns (address _feeDistributorFactory);

    /// @notice returns the address of the minter contract
    /// @return _minter address of the minter
    function minter() external view returns (address _minter);

    /// @notice check if the gauge is active for governance use
    /// @param _gauge address of the gauge
    /// @return _trueOrFalse if the gauge is alive
    function isAlive(address _gauge) external view returns (bool _trueOrFalse);

    /// @notice allows the token to be paired with other whitelisted assets to participate in governance
    /// @param _token the address of the token
    function whitelist(address _token) external;

    /// @notice effectively disqualifies a token from governance
    /// @param _token the address of the token
    function revokeWhitelist(address _token) external;

    /// @notice returns if the address is a gauge
    /// @param gauge address of the gauge
    /// @return _trueOrFalse boolean if the address is a gauge
    function isGauge(address gauge) external view returns (bool _trueOrFalse);

    /// @notice disable a gauge from governance
    /// @param _gauge address of the gauge
    function killGauge(address _gauge) external;

    /// @notice re-activate a dead gauge
    /// @param _gauge address of the gauge
    function reviveGauge(address _gauge) external;

    /// @notice re-cast a tokenID's votes
    /// @param owner address of the owner
    function poke(address owner) external;

    /// @notice sets the main destinationGauge of a token pairing
    /// @param tokenA address of tokenA
    /// @param tokenB address of tokenB
    /// @param destinationGauge the main gauge to set to
    function redirectEmissions(address tokenA, address tokenB, address destinationGauge) external;

    /// @notice returns if the address is a fee distributor
    /// @param _feeDistributor address of the feeDist
    /// @return _trueOrFalse if the address is a fee distributor
    function isFeeDistributor(address _feeDistributor) external view returns (bool _trueOrFalse);

    /// @notice returns the address of the emission's token
    /// @return _ram emissions token contract address
    function ram() external view returns (address _ram);

    /// @notice returns the address of the pool's gauge, if any
    /// @param _pool pool address
    /// @return _gauge gauge address
    function gaugeForPool(address _pool) external view returns (address _gauge);

    /// @notice returns the address of the pool's feeDistributor, if any
    /// @param _gauge address of the gauge
    /// @return _feeDistributor address of the pool's feedist
    function feeDistributorForGauge(address _gauge) external view returns (address _feeDistributor);

    /// @notice returns the gauge address of a CL pool
    /// @param tokenA address of token A in the pair
    /// @param tokenB address of token B in the pair
    /// @param tickSpacing tickspacing of the pool
    /// @return gauge address of the gauge
    function gaugeForClPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address gauge);

    /// @notice returns the array of all tickspacings for the tokenA/tokenB combination
    /// @param tokenA address of token A in the pair
    /// @param tokenB address of token B in the pair
    /// @return _ts array of all the tickspacings
    function tickSpacingsForPair(address tokenA, address tokenB) external view returns (int24[] memory _ts);

    /// @notice returns the destination of a gauge redirect
    /// @param gauge address of gauge
    function gaugeRedirect(address gauge) external view returns (address);

    /// @notice returns the block.timestamp divided by 1 week in seconds
    /// @return period the period used for gauges
    function getPeriod() external view returns (uint256 period);

    /// @notice cast a vote to direct emissions to gauges and earn incentives
    /// @param owner address of the owner
    /// @param _pools the list of pools to vote on
    /// @param _weights an arbitrary weight per pool which will be normalized to 100% regardless of numerical inputs
    function vote(address owner, address[] calldata _pools, uint256[] calldata _weights) external;

    /// @notice reset the vote of an address
    /// @param owner address of the owner
    function reset(address owner) external;

    /// @notice set the governor address
    /// @param _governor the new governor address
    function setGovernor(address _governor) external;

    /// @notice recover stuck emissions
    /// @param _gauge the gauge address
    /// @param _period the period
    function stuckEmissionsRecovery(address _gauge, uint256 _period) external;

    /// @notice creates a legacy gauge for the pool
    /// @param _pool pool's address
    /// @return _gauge address of the new gauge
    function createGauge(address _pool) external returns (address _gauge);

    /// @notice create a concentrated liquidity gauge
    /// @param tokenA the address of tokenA
    /// @param tokenB the address of tokenB
    /// @param tickSpacing the tickspacing of the pool
    /// @return _clGauge address of the new gauge
    function createCLGauge(address tokenA, address tokenB, int24 tickSpacing) external returns (address _clGauge);

    /// @notice create a DLMM rewarder for an existing pool
    /// @param pool the DLMM pool address
    /// @return _dlmmRewarder address of the rewarder target
    function createDLMMRewarder(address pool) external returns (address _dlmmRewarder);

    /// @notice sets the rewarded bin range for a registered DLMM rewarder
    function setDLMMRewarderDeltaBins(address rewarder, int24 deltaBinA, int24 deltaBinB) external;

    /// @notice claim concentrated liquidity gauge rewards for specific NFP token ids
    /// @param _gauges array of gauges
    /// @param _tokens two dimensional array for the tokens to claim
    /// @param _nfpTokenIds two dimensional array for the NFPs
    /// @param _nfpManagers array of NFP manager addresses for each gauge
    function claimClGaugeRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens,
        uint256[][] calldata _nfpTokenIds,
        address[] calldata _nfpManagers
    ) external;

    /// @notice claim concentrated liquidity gauge rewards (backwards compatible - auto-detects NFP managers)
    /// @param _gauges array of gauges
    /// @param _tokens two dimensional array for the tokens to claim
    /// @param _nfpTokenIds two dimensional array for the NFPs
    function claimClGaugeRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens,
        uint256[][] calldata _nfpTokenIds
    ) external;

    /// @notice claim arbitrary rewards from specific feeDists
    /// @param owner address of the owner
    /// @param _feeDistributors address of the feeDists
    /// @param _tokens two dimensional array for the tokens to claim
    function claimIncentives(address owner, address[] calldata _feeDistributors, address[][] calldata _tokens) external;

    /// @notice claim arbitrary rewards from specific feeDists and break up legacy pairs
    /// @param owner address of the owner
    /// @param _feeDistributors address of the feeDists
    /// @param _tokens two dimensional array for the tokens to claim
    function claimLegacyIncentives(address owner, address[] calldata _feeDistributors, address[][] calldata _tokens)
        external;

    /// @notice claim arbitrary rewards from specific gauges
    /// @param _gauges address of the gauges
    /// @param _tokens two dimensional array for the tokens to claim
    function claimRewards(address[] calldata _gauges, address[][] calldata _tokens) external;

    /// @notice distribute emissions to a gauge for a specific period
    /// @param _gauge address of the gauge
    /// @param _period value of the period
    function distributeForPeriod(address _gauge, uint256 _period) external;

    /// @notice attempt distribution of emissions to all gauges
    function distributeAll() external;

    /// @notice distribute emissions to gauges by index
    /// @param startIndex start of the loop
    /// @param endIndex end of the loop
    function batchDistributeByIndex(uint256 startIndex, uint256 endIndex) external;

    /// @notice lets governance update lastDistro period for a gauge
    /// @dev should only be used if distribute() is running out of gas
    /// @dev gaugePeriodDistributed will stop double claiming
    /// @param _gauge gauge to update
    /// @param _period period to update to
    function updateLastDistro(address _gauge, uint256 _period) external;

    /// @notice returns the votes cast for a tokenID
    /// @param owner address of the owner
    /// @return votes an array of votes casted
    /// @return weights an array of the weights casted per pool
    function getVotes(address owner, uint256 period)
        external
        view
        returns (address[] memory votes, uint256[] memory weights);

    /// @notice returns an array of all the pools
    /// @return _pools the array of pools
    function getAllPools() external view returns (address[] memory _pools);

    /// @notice returns the length of pools
    function getPoolsLength() external view returns (uint256);

    /// @notice returns the pool at index
    function getPool(uint256 index) external view returns (address);

    /// @notice returns an array of all the gauges
    /// @return _gauges the array of gauges
    function getAllGauges() external view returns (address[] memory _gauges);

    /// @notice returns the length of gauges
    function getGaugesLength() external view returns (uint256);

    /// @notice returns the gauge at index
    function getGauge(uint256 index) external view returns (address);

    /// @notice returns an array of all the feeDists
    /// @return _feeDistributors the array of feeDists
    function getAllFeeDistributors() external view returns (address[] memory _feeDistributors);

    /// @notice sets the xRamRatio default
    function setGlobalRatio(uint256 _xRatio) external;

    /// @notice whether the token is whitelisted in governance
    function isWhitelisted(address _token) external view returns (bool _tf);

    /// @notice function for removing malicious or stuffed tokens
    function removeFeeDistributorReward(address _feeDist, address _token) external;

    /// @notice returns the total votes for a pool in a specific period
    /// @param pool the pool address to check
    /// @param period the period to check
    /// @return votes the total votes for the pool in that period
    function poolTotalVotesPerPeriod(address pool, uint256 period) external view returns (uint256 votes);

    /// @notice returns the pool address for a given gauge
    /// @param gauge address of the gauge
    /// @return pool address of the pool
    function poolForGauge(address gauge) external view returns (address pool);

    /// @notice returns the pool address for a given feeDistributor
    /// @param feeDistributor address of the feeDistributor
    /// @return pool address of the pool
    function poolForFeeDistributor(address feeDistributor) external view returns (address pool);

    /// @notice returns the voting power used by a voter for a period
    /// @param user address of the user
    /// @param period the period to check
    function userVotingPowerPerPeriod(address user, uint256 period) external view returns (uint256 votingPower);

    /// @notice returns the total votes for a specific period
    /// @param period the period to check
    /// @return weight the total votes for that period
    function totalVotesPerPeriod(uint256 period) external view returns (uint256 weight);

    /// @notice returns the total rewards allocated for a specific period
    /// @param period the period to check
    /// @return amount the total rewards for that period
    function totalRewardPerPeriod(uint256 period) external view returns (uint256 amount);

    /// @notice returns the last distribution period for a gauge
    /// @param _gauge address of the gauge
    /// @return period the last period distributions occurred
    function lastDistro(address _gauge) external view returns (uint256 period);

    /// @notice returns if the gauge is a Cl gauge
    /// @param gauge the gauge to check
    function isClGauge(address gauge) external view returns (bool);

    /// @notice returns if the gauge is a legacy gauge
    /// @param gauge the gauge to check
    function isLegacyGauge(address gauge) external view returns (bool);

    /// @notice returns if the address is a DLMM rewarder target
    /// @param rewarder the rewarder to check
    function isDLMMRewarder(address rewarder) external view returns (bool);

    /// @notice sets a new NFP manager
    function setNfpManager(address _nfpManager) external;

    /// @notice sets the minimum time threshold for rewarder (in seconds)
    function setTimeThresholdForRewarder(uint256 _timeThreshold) external;

    /// @notice returns all voters for a period
    function getAllVotersPerPeriod(uint256 period) external view returns (address[] memory);

    /// @notice returns the length of all voters for a period
    function getAllVotersPerPeriodLength(uint256 period) external view returns (uint256);

    /// @notice returns voter at index for a period
    function getAllVotersPerPeriodAt(uint256 period, uint256 index) external view returns (address);

    /// @notice Update FeeDistributor for a gauge (emergency governance function)
    function updateFeeDistributorForGauge(address _gauge, address _newFeeDistributor) external;

    /// @notice Create a new FeeDistributor with specified feeRecipient (emergency governance function)
    function createFeeDistributorWithRecipient(address _feeRecipient) external returns (address);

    /// @notice returns if the anti-sybil is enabled
    function isAntiSybilEnabled() external view returns (bool);

    /// @notice returns all authorized claimers for CL gauges
    function getAllAuthorizedClaimers() external view returns (address[] memory);

    /// @notice Add a new authorized claimer to the whitelist
    function addAuthorizedClaimer(address _claimer) external;

    /// @notice Remove an authorized claimer from the whitelist
    function removeAuthorizedClaimer(address _claimer) external;

    /// @notice returns if an address can route DLMM liquidity mints for rewarded pools
    function isAuthorizedDLMMManager(address manager) external view returns (bool);

    /// @notice Add a DLMM liquidity manager to the whitelist
    function addAuthorizedDLMMManager(address manager) external;

    /// @notice Remove a DLMM liquidity manager from the whitelist
    function removeAuthorizedDLMMManager(address manager) external;
}
