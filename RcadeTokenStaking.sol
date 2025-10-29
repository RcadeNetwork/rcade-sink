// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RcadeTokenStaking Contract
 * @notice A smart contract for staking RCADE tokens with two staking options
 * @dev This contract implements UUPS upgradeable pattern with access control and security features
 * @dev Rewards calculation and distribution are handled offchain
 */
contract RcadeTokenStaking is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    /********** EVENTS **********/

    /**
     * @notice Event emitted when a new stake is created
     * @param playerId ID of the player
     * @param stakeId The unique identifier of the stake
     * @param user The address of the user who created the stake
     * @param amount The amount of tokens staked
     */
    event StakeCreated(
        address indexed user,
        uint256 indexed stakeId,
        string playerId,
        uint256 amount
    );

    /**
     * @notice Event emitted when tokens are unstaked from a stake
     * @param stakeId The unique identifier of the stake
     * @param amount Amount of tokens unstaked
     * @param status Current status of the stake after unstaking
     */
    event Unstaked(uint256 indexed stakeId, uint256 amount, StakeStatus status);

    /**
     * @notice Event emitted when staking configuration is updated
     * @param newConfig The new staking configuration
     */
    event StakeConfigUpdated(StakeConfig newConfig);

    /**
     * @notice Event emitted when prize pool amount is deposited
     * @param _amount Amount of prize pool deposited
     */
    event PrizePoolAmountDeposited(uint256 _amount);

    /**
     * @notice Event emitted when reward contract address is updated
     * @param _oldAddress Previous reward contract address
     * @param _newAddress New reward contract address
     */
    event RewardContractUpdated(address _oldAddress, address _newAddress);

    /**
     * @notice Event emitted when fees and prize pool are withdrawn to reward contract
     * @param _rewardContract Address of the reward contract
     * @param _feesAmount Amount of fees withdrawn
     * @param _prizePoolAmount Amount of prize pool withdrawn
     */
    event FeesAndPrizePoolWithdrawn(
        address indexed _rewardContract,
        uint256 _feesAmount,
        uint256 _prizePoolAmount
    );

    /********** CONSTANTS **********/

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");
    bytes32 public constant STAKER_ROLE = keccak256("STAKER_ROLE");

    /********** STATE VARIABLES **********/

    /// @notice The RCADE ERC20 token contract.
    IERC20 public rcadeToken;

    /// @notice Counter for generating unique stake IDs.
    using CountersUpgradeable for CountersUpgradeable.Counter;
    CountersUpgradeable.Counter private _stakeIdCounter;

    /// @notice The stake configuration.
    StakeConfig public stakeConfig;

    /// @notice The amount of prize pool tokens.
    uint256 public prizePoolAmount;

    /// @notice The amount of fees collector tokens.
    uint256 public feesCollectorAmount;

    /// @notice The amount of prize pool tokens.
    uint256 public prizePoolAmountDeposited;

    /// @notice The address of the reward contract.
    address public rewardContract;

    /// @notice Mapping from stake ID to stake details.
    mapping(uint256 => Stake) private stakes;

    /// @notice Mapping from player ID to array of their stake IDs.
    mapping(string => uint256[]) private playerIdStakes;

    /// @notice Mapping from player ID to total number of stakes.
    mapping(string => uint256) private playerIdStakeCount;

    /********** STRUCTS **********/

    /**
     * @notice Struct representing a stake
     * @param stakeId Unique identifier for the stake
     * @param wallet Address of the staker
     * @param amount Amount of RCADE tokens staked
     * @param d1ClaimableAmount Amount of RCADE tokens claimable for the first duration
     * @param d2ClaimableAmount Amount of RCADE tokens claimable for the second duration
     * @param status Current status of the stake (active or completed)
     */
    struct Stake {
        address wallet;
        uint96 amount;
        uint32 d1ClaimableAt;
        uint32 d2ClaimableAt;
        uint96 d1ClaimableAmount;
        uint96 d2ClaimableAmount;
        StakeStatus status;
    }

    /**
     * @notice Struct representing the stake configuration
     * @param stakeDurationD1 Duration in seconds for first stake period
     * @param stakeDurationD2 Duration in seconds for second stake period
     * @param feesPercentage Percentage of the stake that goes to the fees collector
     * @param prizePoolPercentage Percentage of the stake that goes to the prize pool
     * @param d1StakePercentage Percentage of the stake that goes to the first stake duration
     * @param d2StakePercentage Percentage of the stake that goes to the second stake duration
     */
    struct StakeConfig {
        uint256 stakeDurationD1;
        uint256 stakeDurationD2;
        uint256 feesPercentage;
        uint256 prizePoolPercentage;
        uint256 d1StakePercentage;
        uint256 d2StakePercentage;
    }

    /********** ENUMS **********/

    /**
     * @notice Enum representing the status of a stake
     * @dev ACTIVE - Stake is currently locked
     * @dev D1CLAIMED - First duration tokens have been claimed
     * @dev COMPLETED - Stake has been fully unstaked (all tokens withdrawn)
     */
    enum StakeStatus {
        ACTIVE,
        D1CLAIMED,
        COMPLETED
    }

    /**
     * @notice Enum representing the time elapsed since the stake was created
     * @dev BEFORE_D1 - Time elapsed is before the first duration
     * @dev AFTER_D1 - Time elapsed is after the first duration
     * @dev AFTER_D2 - Time elapsed is after the second duration
     */
    enum TimeElapsed {
        BEFORE_D1,
        AFTER_D1,
        AFTER_D2
    }

    /********** ERRORS **********/

    /// @notice Error thrown when a stake cannot be found.
    error StakeNotFound();

    /// @notice Error thrown when trying to unstake an already completed stake.
    error AlreadyUnstaked();

    /// @notice Error thrown when caller lacks required permissions.
    error Unauthorized();

    /// @notice Error thrown when an invalid address is provided.
    error InvalidAddress();

    /// @notice Error thrown when duration seconds cannot be zero.
    error DurationSecondsCannotBeZero();

    /// @notice Error thrown when an invalid duration seconds is provided.
    error InvalidDurationSeconds();

    /// @notice Error thrown when an invalid percentage is provided.
    error InvalidPercentage();

    /// @notice Error thrown when config is not set.
    error ConfigNotSet();

    /// @notice Error thrown when no tokens are available to claim.
    error NoTokensAvailableToClaim();

    /// @notice Error thrown when an invalid value is provided.
    error InvalidValue();

    /********** INITIALIZATION **********/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _rcadeToken Address of the RCADE token contract
     * @param _admin Address to receive DEFAULT_ADMIN_ROLE
     */
    function initialize(
        address _rcadeToken,
        address _admin
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _isValidAddress(_rcadeToken);
        _isValidAddress(_admin);

        rcadeToken = IERC20(_rcadeToken);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(MAINTAINER_ROLE, _admin);
        _grantRole(STAKER_ROLE, _admin);

        _stakeIdCounter.increment();
    }

    /********** CORE STAKING FUNCTIONS **********/

    /**
     * @notice Create a new stake
     * @param playerId ID of the player
     * @param amount Amount of RCADE tokens to stake
     */
    function stake(
        string calldata playerId,
        uint256 amount
    ) public whenNotPaused onlyRole(STAKER_ROLE) {
        _isConfigSet();

        prizePoolAmount =
            prizePoolAmount +
            (amount * stakeConfig.prizePoolPercentage) /
            100;
        feesCollectorAmount =
            feesCollectorAmount +
            (amount * stakeConfig.feesPercentage) /
            100;

        uint256 d1ClaimableAmount = (amount * stakeConfig.d1StakePercentage) /
            100;
        uint256 d2ClaimableAmount = (amount * stakeConfig.d2StakePercentage) /
            100;

        rcadeToken.transferFrom(tx.origin, address(this), amount);

        if (d1ClaimableAmount == 0 && d2ClaimableAmount == 0) {
            return;
        }

        uint256 stakeId = _stakeIdCounter.current();
        _stakeIdCounter.increment();
        uint256 stakedAt = block.timestamp;
        uint256 d1ClaimableAt = stakedAt + stakeConfig.stakeDurationD1;
        uint256 d2ClaimableAt = stakedAt + stakeConfig.stakeDurationD2;

        stakes[stakeId] = Stake({
            wallet: tx.origin,
            amount: uint96(amount),
            d1ClaimableAt: uint32(d1ClaimableAt),
            d2ClaimableAt: uint32(d2ClaimableAt),
            d1ClaimableAmount: uint96(d1ClaimableAmount),
            d2ClaimableAmount: uint96(d2ClaimableAmount),
            status: StakeStatus.ACTIVE
        });

        playerIdStakes[playerId].push(stakeId);
        playerIdStakeCount[playerId]++;

        emit StakeCreated(tx.origin, stakeId, playerId, amount);
    }

    /**
     * @notice Claim available tokens from a stake
     * @param stakeId ID of the stake to claim from
     */
    function unstake(uint256 stakeId) external nonReentrant whenNotPaused {
        Stake storage stakeData = stakes[stakeId];
        TimeElapsed timeElapsed = _isValidStake(stakeId);

        uint256 availableToClaim;

        if (timeElapsed == TimeElapsed.BEFORE_D1) {
            revert NoTokensAvailableToClaim();
        } else if (
            timeElapsed == TimeElapsed.AFTER_D1 &&
            stakeData.status == StakeStatus.ACTIVE
        ) {
            stakeData.status = StakeStatus.D1CLAIMED;
            availableToClaim = uint256(stakeData.d1ClaimableAmount);
        } else if (timeElapsed == TimeElapsed.AFTER_D2) {
            if (stakeData.status == StakeStatus.ACTIVE) {
                stakeData.status = StakeStatus.COMPLETED;
                availableToClaim = uint256(
                    stakeData.d1ClaimableAmount + stakeData.d2ClaimableAmount
                );
            } else {
                stakeData.status = StakeStatus.COMPLETED;
                availableToClaim = uint256(stakeData.d2ClaimableAmount);
            }
        } else {
            revert NoTokensAvailableToClaim();
        }

        rcadeToken.transfer(msg.sender, availableToClaim);

        emit Unstaked(stakeId, availableToClaim, stakeData.status);
    }

    /********** ADMINISTRATIVE FUNCTIONS **********/

    /**
     * @notice Deposit prize pool amount
     * @param _amount Amount of prize pool to deposit
     */
    function depositPrizePoolAmount(
        uint256 _amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _isValidValue(_amount);

        rcadeToken.transferFrom(msg.sender, address(this), _amount);

        prizePoolAmountDeposited = prizePoolAmountDeposited + _amount;
        prizePoolAmount = prizePoolAmount + _amount;

        emit PrizePoolAmountDeposited(_amount);
    }

    /**
     * @notice Set the reward contract address
     * @param _rewardContract Address of the reward contract
     */
    function setRewardContract(
        address _rewardContract
    ) external onlyRole(MAINTAINER_ROLE) {
        _isValidAddress(_rewardContract);

        address oldAddress = rewardContract;
        rewardContract = _rewardContract;

        emit RewardContractUpdated(oldAddress, _rewardContract);
    }

    /**
     * @notice Withdraw all fees and prize pool tokens to reward contract
     * @dev This function transfers all accumulated fees and prize pool tokens to the reward contract
     * @dev and resets the state variables to zero, keeping only tokens needed for user claims
     */
    function withdrawFeesAndPrizePool() external onlyRole(MAINTAINER_ROLE) {
        _isValidAddress(rewardContract);

        uint256 totalAmount = feesCollectorAmount + prizePoolAmount;
        _isValidValue(totalAmount);

        // Transfer all tokens to reward contract
        rcadeToken.transfer(rewardContract, totalAmount);

        emit FeesAndPrizePoolWithdrawn(
            rewardContract,
            feesCollectorAmount,
            prizePoolAmount
        );

        // Reset state variables to zero
        feesCollectorAmount = 0;
        prizePoolAmount = 0;
        prizePoolAmountDeposited = 0;
    }

    /**
     * @notice Update staking configuration
     * @param newStakeConfig New staking configuration struct
     */
    function setStakeConfig(
        StakeConfig calldata newStakeConfig
    ) external onlyRole(MAINTAINER_ROLE) {
        _isValidDurationSeconds(
            newStakeConfig.stakeDurationD1,
            newStakeConfig.stakeDurationD2
        );
        _isValidPercentage(
            newStakeConfig.feesPercentage,
            newStakeConfig.prizePoolPercentage,
            newStakeConfig.d1StakePercentage,
            newStakeConfig.d2StakePercentage
        );

        stakeConfig = newStakeConfig;

        emit StakeConfigUpdated(stakeConfig);
    }

    /**
     * @notice Pause staking operations
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause staking operations
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Upgrade the contract implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    /********** VIEW FUNCTIONS **********/

    /**
     * @notice Get the amount available to claim for a stake
     * @param stakeId ID of the stake
     * @return timeElapsed Time elapsed since the stake was created
     */
    function _getTimeElapsed(
        uint256 stakeId
    ) internal view returns (TimeElapsed timeElapsed) {
        Stake memory stakeData = stakes[stakeId];

        uint256 currentTime = block.timestamp;

        if (currentTime < stakeData.d1ClaimableAt) {
            return TimeElapsed.BEFORE_D1;
        } else if (currentTime < stakeData.d2ClaimableAt) {
            return TimeElapsed.AFTER_D1;
        } else {
            return TimeElapsed.AFTER_D2;
        }
    }

    /**
     * @notice Get paginated stakes for a user
     * @param playerId ID of the player
     * @param offset Starting index for pagination
     * @param limit Maximum number of stakes to return
     * @return stakeIds Array of stake IDs for the user
     * @return stakeDetails Array of stake details
     * @return totalStakes Total number of stakes for the user
     */
    function getUserStakes(
        string memory playerId,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (
            uint256[] memory stakeIds,
            Stake[] memory stakeDetails,
            uint256 totalStakes
        )
    {
        totalStakes = playerIdStakeCount[playerId];

        if (offset >= totalStakes) {
            return (new uint256[](0), new Stake[](0), totalStakes);
        }

        uint256 endIndex = offset + limit;
        if (endIndex > totalStakes) {
            endIndex = totalStakes;
        }

        uint256 resultLength = endIndex - offset;
        stakeIds = new uint256[](resultLength);
        stakeDetails = new Stake[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            uint256 stakeId = playerIdStakes[playerId][offset + i];
            stakeIds[i] = stakeId;
            stakeDetails[i] = stakes[stakeId];
        }
    }

    /********** INTERNAL FUNCTIONS **********/

    /**
     * @notice Validate stake for unstaking operations and return available amount
     * @param stakeId The stake ID to validate
     * @return timeElapsed Time elapsed since the stake was created
     */
    function _isValidStake(
        uint256 stakeId
    ) internal view returns (TimeElapsed timeElapsed) {
        Stake memory stakeData = stakes[stakeId];

        if (stakeData.wallet == address(0)) revert StakeNotFound();
        if (stakeData.wallet != msg.sender) revert Unauthorized();
        if (stakeData.status == StakeStatus.COMPLETED) revert AlreadyUnstaked();

        timeElapsed = _getTimeElapsed(stakeId);
    }

    /**
     * @notice Validate address is not zero address
     * @param _address Address to validate
     */
    function _isValidAddress(address _address) internal pure {
        if (_address == address(0)) revert InvalidAddress();
    }

    /**
     * @notice Validate value
     * @param _value Value to validate
     */
    function _isValidValue(uint256 _value) internal pure {
        if (_value == 0) revert InvalidValue();
    }

    /**
     * @notice Validate staking duration seconds
     * @param _firstStakeDurationSeconds Duration in seconds for first stake period
     * @param _secondStakeDurationSeconds Duration in seconds for second stake period
     */
    function _isValidDurationSeconds(
        uint256 _firstStakeDurationSeconds,
        uint256 _secondStakeDurationSeconds
    ) internal pure {
        if (_firstStakeDurationSeconds == 0 || _secondStakeDurationSeconds == 0)
            revert DurationSecondsCannotBeZero();
        if (_secondStakeDurationSeconds <= _firstStakeDurationSeconds)
            revert InvalidDurationSeconds();
    }

    /**
     * @notice Validate percentage
     * @param _feesPercentage Percentage of the stake that goes to the fees collector
     * @param _prizePoolPercentage Percentage of the stake that goes to the prize pool
     * @param _d1StakePercentage Percentage of the stake that goes to the first stake duration
     * @param _d2StakePercentage Percentage of the stake that goes to the second stake duration
     */
    function _isValidPercentage(
        uint256 _feesPercentage,
        uint256 _prizePoolPercentage,
        uint256 _d1StakePercentage,
        uint256 _d2StakePercentage
    ) internal pure {
        if (
            _d1StakePercentage +
                _d2StakePercentage +
                _feesPercentage +
                _prizePoolPercentage !=
            100
        ) revert InvalidPercentage();
    }

    /**
     * @notice Validate config is set
     */
    function _isConfigSet() internal view {
        StakeConfig memory _config = stakeConfig;

        _isValidPercentage(
            _config.feesPercentage,
            _config.prizePoolPercentage,
            _config.d1StakePercentage,
            _config.d2StakePercentage
        );

        _isValidDurationSeconds(
            _config.stakeDurationD1,
            _config.stakeDurationD2
        );
    }
}
