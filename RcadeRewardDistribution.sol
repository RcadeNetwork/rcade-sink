// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./lib/LibSignatureVerify.sol";
/**
 * @title RcadeRewardDistribution Contract
 * @notice A smart contract for staking RCADE tokens with two staking options
 * @dev This contract implements UUPS upgradeable pattern with access control and security features
 * @dev Rewards calculation and distribution are handled offchain
 */
contract RcadeRewardDistribution is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
 
    /********** EVENTS **********/

    /**
     * @notice Event emitted when reward is claimed
     * @param playerId The player ID of the user whose reward is being claimed.
     * @param eventId The event ID of the user whose reward is being claimed.
     */
    event RewardClaimed(address indexed wallet, string indexed playerId, uint256 eventId, uint256 amount);

    /**
     * @notice Event emitted when the RCADE token contract is updated
     * @param oldRcadeToken The old RCADE token contract
     * @param newRcadeToken The new RCADE token contract
     */
    event RcadeTokenUpdated(address indexed oldRcadeToken, address indexed newRcadeToken);

    /**
     * @notice Event emitted when the trusted signer is updated
     * @param oldTrustedSigner The old trusted signer
     * @param newTrustedSigner The new trusted signer
     */
    event TrustedSignerUpdated(address indexed oldTrustedSigner, address indexed newTrustedSigner);

    /**
     * @notice Event emitted when the event ID is updated
     * @param eventId The new event ID
     */
    event EventIdUpdated(uint256 indexed eventId);

    /********** CONSTANTS **********/

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /********** STATE VARIABLES **********/

    /// @dev The RCADE token contract
    IERC20 public rcadeToken;

    /// @dev The trusted signer address for signature verification
    address public trustedSigner;

    /// @dev The claimed amounts for each player ID
    mapping(string => uint256) public lastClaimedEventId;

    /// @dev The event ID
    uint256 public currentEventId;

    // store which event ids have been set by admin so far to avoid setting the same event id again
    mapping(uint256 => bool) public eventIdsSet;

    /********** ERRORS **********/

    /// @notice Error thrown when an invalid address is provided
    error InvalidAddress();

    /// @notice Error thrown when an invalid signature is provided
    error InvalidSignature();

    /// @notice Error thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Error thrown when an invalid player ID is provided
    error InvalidPlayerId();

    /// @notice Error thrown when an amount has already been claimed
    error AlreadyClaimed();

    /// @notice Error thrown when an invalid event ID is provided
    error InvalidEventId();

    /// @notice Error thrown when an event ID is expired
    error EventIdExpired();

    /// @notice Error thrown when an event ID has already been set
    error EventIdAlreadySet();

    /********** INITIALIZATION **********/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _admin Address to receive all the roles
     * @param _rcadeToken Address of the RCADE token contract
     * @param _trustedSigner Address of the trusted signer
     */
    function initialize(
        address _admin,
        address _rcadeToken,
        address _trustedSigner,
        uint256 _eventId
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _isValidAddress(_admin);
        _isValidAddress(_rcadeToken);
        _isValidAddress(_trustedSigner);
        _isValidEventId(_eventId);

        currentEventId = _eventId;
        eventIdsSet[_eventId] = true;
        rcadeToken = IERC20(_rcadeToken);
        trustedSigner = _trustedSigner;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    /********** CORE FUNCTIONS **********/

    /**
     * @notice Claim reward from the contract
     * @param playerId The player ID of the user whose reward is being claimed.
     * @param amount The cumulative total amount allowed for this player ID.
     * @param signature The EIP-712 signature from the backend signer.
     */
    function claimReward(
        string memory playerId,
        uint256 amount,
        uint256 eventId,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        _isValidPlayerId(playerId);
        _isValidAmount(amount, playerId);
        _isValidEventIdForClaim(eventId);

        bool isValid = _verifyRewardClaimSignature(playerId, amount, eventId, signature);

        if (!isValid) {
            revert InvalidSignature();
        }

        lastClaimedEventId[playerId] = eventId;

        rcadeToken.transfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, playerId, eventId, amount);
    }

    /********** ADMINISTRATIVE FUNCTIONS **********/

    /**
     * @notice Update the trusted signer
     * @param _trustedSigner Address of the trusted signer
     */
    function updateTrustedSigner(
        address _trustedSigner
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _isValidAddress(_trustedSigner);

        address oldTrustedSigner = trustedSigner;
        trustedSigner = _trustedSigner;

        emit TrustedSignerUpdated(oldTrustedSigner, _trustedSigner);
    }

    /**
     * @notice Update the RCADE token contract
     * @param _rcadeToken Address of the RCADE token contract
     */
    function updateRcadeToken(
        address _rcadeToken
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _isValidAddress(_rcadeToken);

        address oldRcadeToken = address(rcadeToken);
        rcadeToken = IERC20(_rcadeToken);

        emit RcadeTokenUpdated(oldRcadeToken, _rcadeToken);
    }

    /**
     * @notice Update the event ID
     * @param _eventId Event ID to update
     */
    function updateEventId(
        uint256 _eventId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _isValidEventId(_eventId);
        currentEventId = _eventId;
        eventIdsSet[_eventId] = true;
        emit EventIdUpdated(_eventId);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Upgrade the contract
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    /********** INTERNAL FUNCTIONS **********/

    /**
     * @notice Validate address is not zero address
     * @param _address Address to validate
     */
    function _isValidAddress(address _address) internal pure {
        if (_address == address(0)) revert InvalidAddress();
    }

    /**
     * @notice Validate event ID is valid
     * @param _eventId Event ID to validate
     * @dev The event ID must be greater than 0 and the event ID must be the current event ID
    */
    function _isValidEventId(uint256 _eventId) internal view {
        if (_eventId == 0) revert InvalidEventId();
        if (eventIdsSet[_eventId]) revert EventIdAlreadySet();
    }

    /**
     * @notice Validate event ID is not zero
     * @param _eventId Event ID to validate
     */
    function _isValidEventIdForClaim(uint256 _eventId) internal view {
        if (_eventId == 0) revert InvalidEventId();
        if (_eventId != currentEventId) revert EventIdExpired();
    }

    /**
     * @notice Validate player ID is not empty
     * @param _playerId Player ID to validate
     */
    function _isValidPlayerId(string memory _playerId) internal pure {
        if (bytes(_playerId).length == 0) revert InvalidPlayerId();
    }

    /**
     * @notice Validate amount is greater than zero
     * @param _amount Amount to validate
     */
    function _isValidAmount(uint256 _amount, string memory playerId) internal view {
            if (_amount == 0) revert InvalidAmount();
            if (lastClaimedEventId[playerId] == currentEventId) revert AlreadyClaimed();
    }

    /**
     * @notice Verify a reward claim attestation signature for a user.
     * @param playerId The player ID of the user whose reward is being claimed.
     * @param amount The amount of reward being claimed.
     * @param signature The EIP-712 signature from the backend signer.
     */
    function _verifyRewardClaimSignature(
        string memory playerId,
        uint256 amount,
        uint256 eventId,
        bytes calldata signature
    ) internal view returns (bool) {
        return
            LibSignatureVerify.verifyRewardClaim(
                playerId,
                amount,
                eventId,
                signature,
                trustedSigner,
                address(this)
            );
    }
}
