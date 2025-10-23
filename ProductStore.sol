// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title IQuoterV2 Interface
 * @notice Interface for Uniswap V3 QuoterV2 contract
 * @dev Used for getting price quotes for token swaps
 */
interface IQuoterV2 {
    function quoteExactInput(
        bytes memory path,
        uint256 amountIn
    )
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

/**
 * @title IStakingContract Interface
 * @notice Interface for the RCADE token staking contract
 * @dev Used for automatically staking RCADE tokens when purchased
 */
interface IStakingContract {
    function stake(string calldata playerId, uint256 amount) external;
}

/**
 * @title InitializeParams Struct
 * @notice Parameters required for contract initialization
 * @param initialOwner Address to receive ownership of the contract
 * @param treasury Address to receive USDT payments
 * @param usdtToken Address of the USDT token contract
 * @param rcadeToken Address of the RCADE token contract
 * @param quoterContract Address of the Uniswap V3 QuoterV2 contract
 * @param stakingContract Address of the staking contract
 * @param slippage Slippage tolerance in permille (e.g., 30 = 3%)
 * @param path Uniswap swap path for USDT to RCADE conversion
 */
struct InitializeParams {
    address initialOwner;
    address treasury;
    address usdtToken;
    address rcadeToken;
    address quoterContract;
    address stakingContract;
    uint256 slippage;
    bytes path;
}

/**
 * @title ProductStore Contract
 * @notice A smart contract for managing gaming products with dual payment system (USDT/RCADE)
 * @dev This contract implements UUPS upgradeable pattern with access control and security features
 * @dev Supports automatic token conversion and staking integration for RCADE payments
 */
contract ProductStore is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    /********** EVENTS **********/

    /**
     * @notice Event emitted when new products are added to the store
     * @param productIds Array of product IDs that were added
     * @param prices Array of USDT prices for the products
     * @param timestamp Block timestamp when products were added
     */
    event ProductAdded(string[] productIds, uint[] prices, uint256 timestamp);

    /**
     * @notice Event emitted when product prices are updated
     * @param productId Array of product IDs that were updated
     * @param prices Array of new USDT prices for the products
     * @param timestamp Block timestamp when products were updated
     */
    event ProductUpdated(string[] productId, uint[] prices, uint256 timestamp);

    /**
     * @notice Event emitted when a product is deleted from the store
     * @param productId ID of the product that was deleted
     * @param timestamp Block timestamp when product was deleted
     */
    event ProductDeleted(string indexed productId, uint256 timestamp);

    /**
     * @notice Event emitted when a product is purchased
     * @param buyer Address of the buyer
     * @param playerId ID of the player making the purchase
     * @param productId ID of the product purchased
     * @param offerId ID of the offer (for tracking purposes)
     * @param paymentToken Address of the token used for payment
     * @param amountPaid Amount of tokens paid for the product
     * @param timestamp Block timestamp when purchase was made
     */
    event ProductPurchased(
        address indexed buyer,
        string playerId,
        string productId,
        uint offerId,
        address paymentToken,
        uint amountPaid,
        uint256 timestamp
    );

    /**
     * @notice Event emitted when treasury address is updated
     * @param oldTreasury Previous treasury address
     * @param newTreasury New treasury address
     * @param timestamp Block timestamp when treasury was updated
     */
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury,
        uint256 timestamp
    );

    /**
     * @notice Event emitted when slippage tolerance is updated
     * @param oldSlippage Previous slippage value
     * @param newSlippage New slippage value
     * @param timestamp Block timestamp when slippage was updated
     */
    event SlippageUpdated(
        uint256 indexed oldSlippage,
        uint256 indexed newSlippage,
        uint256 timestamp
    );


    /**
     * @notice Event emitted when quoter contract is updated
     * @param oldQuoter Previous quoter contract address
     * @param newQuoter New quoter contract address
     * @param timestamp Block timestamp when quoter was updated
     */
    event QuoterUpdated(
        address indexed oldQuoter,
        address indexed newQuoter,
        uint256 timestamp
    );

    /**
     * @notice Event emitted when USDT token contract is updated
     * @param oldUSDTToken Previous USDT token address
     * @param newUSDTToken New USDT token address
     * @param timestamp Block timestamp when USDT token was updated
     */
    event USDTTokenUpdated(
        address indexed oldUSDTToken,
        address indexed newUSDTToken,
        uint256 timestamp
    );

    /**
     * @notice Event emitted when RCADE token contract is updated
     * @param oldRcadeToken Previous RCADE token address
     * @param newRcadeToken New RCADE token address
     * @param timestamp Block timestamp when RCADE token was updated
     */
    event RcadeTokenUpdated(
        address indexed oldRcadeToken,
        address indexed newRcadeToken,
        uint256 timestamp
    );

    /**
     * @notice Event emitted when staking contract is updated
     * @param oldStakingContract Previous staking contract address
     * @param newStakingContract New staking contract address
     * @param timestamp Block timestamp when staking contract was updated
     */
    event StakingContractUpdated(
        address indexed oldStakingContract,
        address indexed newStakingContract,
        uint256 timestamp
    );

    /**
     * @notice Event emitted when Uniswap swap path is updated
     * @param oldPath Previous swap path
     * @param newPath New swap path
     * @param timestamp Block timestamp when path was updated
     */
    event PathUpdated(
        bytes indexed oldPath,
        bytes indexed newPath,
        uint256 timestamp
    );

    /********** STATE VARIABLES **********/

    /// @notice Address of the treasury that receives USDT payments
    address public _treasury;

    /// @notice USDT token contract interface
    IERC20 public _usdtToken;

    /// @notice Mapping from product ID to USDT price
    mapping(string productId => uint price) public _productPrice;

    /// @notice Uniswap V3 QuoterV2 contract for price quotes
    IQuoterV2 public _quoterContract;

    /// @notice RCADE token contract interface
    ERC20 public _rcadeToken;

    /// @notice Slippage tolerance in permille (e.g. 30 = 3%)
    uint256 public _slippage;

    /// @notice Uniswap swap path for USDT to RCADE conversion
    bytes public _path;

    /// @notice Staking contract interface for automatic RCADE staking
    IStakingContract public _stakingContract;

    /// @notice Maximum allowed slippage in permille (e.g. 50 = 5%)
    uint256 public constant MAX_SLIPPAGE = 50;

    /********** CONSTRUCTOR **********/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /********** INITIALIZATION **********/

    /**
     * @notice Initialize the contract with required parameters
     * @param params Struct containing all initialization parameters
     * @dev This function can only be called once during contract deployment
     */
    function initialize(InitializeParams calldata params) public initializer {
        _isValidAddress(params.initialOwner);
        _isValidAddress(params.treasury);
        _validateSlippage(params.slippage);
        __Pausable_init();
        __Ownable_init(params.initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _usdtToken = IERC20(params.usdtToken);
        _rcadeToken = ERC20(params.rcadeToken);
        _quoterContract = IQuoterV2(params.quoterContract);
        _stakingContract = IStakingContract(params.stakingContract);
        _treasury = params.treasury;
        _slippage = params.slippage;
        _path = params.path;
    }

    /********** PRODUCT MANAGEMENT FUNCTIONS **********/

    /**
     * @notice Add new products to the store
     * @param productIds Array of product IDs to add
     * @param prices Array of USDT prices for the products (in USDT decimals)
     * @dev Only the contract owner can add products
     * @dev Arrays must have the same length
     * @dev Product IDs must not already exist
     * @dev Prices must be greater than zero
     */
    function addProduct(
        string[] calldata productIds,
        uint[] calldata prices
    ) external onlyOwner {
        require(
            productIds.length == prices.length,
            "ProductStore: Array length mismatched"
        );
        for (uint256 i = 0; i < productIds.length; i++) {
            _checkIsProductNotExists(productIds[i]);
            _validatePrice(prices[i]);
            _productPrice[productIds[i]] = prices[i];
        }
        emit ProductAdded(productIds, prices, block.timestamp);
    }

    /**
     * @notice Update prices of existing products
     * @param productIds Array of product IDs to update
     * @param prices Array of new USDT prices for the products (in USDT decimals)
     * @dev Only the contract owner can update products
     * @dev Arrays must have the same length
     * @dev Product IDs must already exist
     * @dev Prices must be greater than zero
     */
    function updateProduct(
        string[] calldata productIds,
        uint[] calldata prices
    ) external onlyOwner {
        require(
            productIds.length == prices.length,
            "ProductStore: Array length mismatched"
        );
        for (uint256 i = 0; i < productIds.length; i++) {
            _checkIsProductExists(productIds[i]);
            _validatePrice(prices[i]);
            _productPrice[productIds[i]] = prices[i];
        }
        emit ProductUpdated(productIds, prices, block.timestamp);
    }

    /**
     * @notice Delete a product from the store
     * @param productId ID of the product to delete
     * @dev Only the contract owner can delete products
     * @dev Product must exist before deletion
     */
    function deleteProduct(
        string calldata productId
        ) external onlyOwner {
        _checkIsProductExists(productId);
        delete _productPrice[productId];
        emit ProductDeleted(productId, block.timestamp);
    }

    /********** PURCHASE FUNCTIONS **********/

    /**
     * @notice Purchase a product using USDT or RCADE tokens
     * @param playerId ID of the player making the purchase
     * @param productId ID of the product to purchase
     * @param offerId ID of the offer (for tracking purposes)
     * @param paymentToken Address of the token to use for payment (USDT or RCADE)
     * @dev If USDT is used: transfers USDT directly to treasury
     * @dev If RCADE is used: converts USDT price to RCADE and stakes the tokens
     * @dev Contract must not be paused
     * @dev Reentrancy protection is applied
     */
    function purchase(
        string calldata playerId,
        string calldata productId,
        uint offerId,
        address paymentToken
    ) external whenNotPaused nonReentrant {
        _checkIsProductExists(productId);
        _checkTokenSupported(paymentToken);

        address buyer = msg.sender;
        uint productPrice = _productPrice[productId];
        uint256 amountToPay;

        if (paymentToken == address(_usdtToken)) {
            amountToPay = productPrice;
            _usdtToken.transferFrom(buyer, _treasury, amountToPay);
        } else {
            (uint amountOut, , , ) = _quoterContract.quoteExactInput(
                _path,
                productPrice
            );
            amountToPay = amountOut;
            _stakingContract.stake(playerId, amountToPay);
        }

        emit ProductPurchased(
            buyer,
            playerId,
            productId,
            offerId,
            paymentToken,
            amountToPay,
            block.timestamp
        );
    }

    /********** ADMINISTRATIVE FUNCTIONS **********/

    /**
     * @notice Update slippage tolerance for price quotes
     * @param slippage New slippage tolerance in permille (e.g., 30 = 3%)
     * @dev Only the contract owner can update slippage
     * @dev Slippage cannot exceed MAX_SLIPPAGE (5%)
     */
    function updateSlippage(
        uint256 slippage
        ) external onlyOwner {
        _validateSlippage(slippage);
        uint256 oldSlippage = _slippage;
        _slippage = slippage;
        emit SlippageUpdated(oldSlippage, slippage, block.timestamp);
    }


    /**
     * @notice Update Uniswap swap path for USDT to RCADE conversion
     * @param newPath New swap path for token conversion
     * @dev Only the contract owner can update the path
     * @dev Path must be valid for USDT to RCADE conversion
     */
    function updatePath(
        bytes calldata newPath
        ) external onlyOwner {
        bytes memory oldPath = _path;
        _path = newPath;
        emit PathUpdated(oldPath, newPath, block.timestamp);
    }

    /**
     * @notice Update USDT token contract address
     * @param newContract Address of the new USDT token contract
     * @dev Only the contract owner can update the USDT contract
     * @dev New contract address must be valid (not zero address)
     */
    function updateUSDTContract(
        address newContract
        ) external onlyOwner {
        _isValidAddress(newContract);
        address oldUSDTToken = address(_usdtToken);
        _usdtToken = IERC20(newContract);
        emit USDTTokenUpdated(oldUSDTToken, newContract, block.timestamp);
    }

    /**
     * @notice Update RCADE token contract address
     * @param newContract Address of the new RCADE token contract
     * @dev Only the contract owner can update the RCADE contract
     * @dev New contract address must be valid (not zero address)
     */
    function updateRcadeContract(
        address newContract
        ) external onlyOwner {
        _isValidAddress(newContract);
        address oldRcadeToken = address(_rcadeToken);
        _rcadeToken = ERC20(newContract);
        emit RcadeTokenUpdated(oldRcadeToken, newContract, block.timestamp);
    }

    /**
     * @notice Update treasury address for USDT payments
     * @param newTreasury Address of the new treasury
     * @dev Only the contract owner can update the treasury
     * @dev New treasury address must be valid (not zero address)
     */
    function updateTreasury(
        address newTreasury
        ) external onlyOwner {
        _isValidAddress(newTreasury);
        address oldTreasury = _treasury;
        _treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury, block.timestamp);
    }

    /**
     * @notice Update Uniswap QuoterV2 contract address
     * @param newQuoter Address of the new QuoterV2 contract
     * @dev Only the contract owner can update the quoter contract
     * @dev New contract address must be valid (not zero address)
     */
    function updateQuoterContract(
        address newQuoter
        ) public onlyOwner {
        _isValidAddress(newQuoter);
        address oldQuoter = address(_quoterContract);
        _quoterContract = IQuoterV2(newQuoter);
        emit QuoterUpdated(oldQuoter, newQuoter, block.timestamp);
    }

    /**
     * @notice Update staking contract address
     * @param newStakingContract Address of the new staking contract
     * @dev Only the contract owner can update the staking contract
     * @dev New contract address must be valid (not zero address)
     */
    function updateStakingContract(
        address newStakingContract
    ) public onlyOwner {
        address oldStakingContract = address(_stakingContract);
        _stakingContract = IStakingContract(newStakingContract);
        emit StakingContractUpdated(
            oldStakingContract,
            newStakingContract,
            block.timestamp
        );
    }

    /********** VIEW FUNCTIONS **********/
    /**
     * @notice Get price quote with slippage applied
     * @param amountIn Input amount for the quote
     * @return amountOut Base amount out from the quote
     * @return amountOutWithSlippage Amount out with slippage applied
     * @dev Calls Uniswap QuoterV2 to get the base quote, then applies slippage
     */
    function getQuoteWithSlippage(
        uint256 amountIn
    ) public returns (uint256 amountOut, uint256 amountOutWithSlippage) {
        (amountOut, , , ) = _quoterContract.quoteExactInput(_path, amountIn);
        amountOutWithSlippage = getAmountWithSlippage(amountOut);
    }

    /********** INTERNAL FUNCTIONS **********/

    /**
     * @notice Check if a product exists in the store
     * @param productId ID of the product to check
     * @dev Reverts if product does not exist (price is 0)
     */
    function _checkIsProductExists(string calldata productId) private view {
        require(
            _productPrice[productId] > 0,
            "ProductStore: Product not found"
        );
    }

    /**
     * @notice Calculate amount with slippage applied
     * @param amount Base amount to apply slippage to
     * @return Amount with slippage added
     * @dev Slippage is calculated as a percentage of the base amount
     * @dev Slippage is stored in permille (e.g., 30 = 3%)
     */
    function getAmountWithSlippage(
        uint256 amount
    ) private view returns (uint256) {
        uint256 slippageAmount = (amount * _slippage) / 1000;
        return amount + slippageAmount;
    }

    /**
     * @notice Check if a product does not exist in the store
     * @param productId ID of the product to check
     * @dev Reverts if product already exists (price is not 0)
     */
    function _checkIsProductNotExists(string calldata productId) private view {
        require(
            _productPrice[productId] == 0,
            "ProductStore: Product already exists"
        );
    }

    /**
     * @notice Validate that an address is not the zero address
     * @param addr Address to validate
     * @dev Reverts if address is zero address
     */
    function _isValidAddress(address addr) private pure {
        require(addr != address(0), "ProductStore: Invalid address");
    }

    /**
     * @notice Validate that slippage is within acceptable limits
     * @param slippage Slippage value to validate
     * @dev Reverts if slippage exceeds MAX_SLIPPAGE
     */
    function _validateSlippage(uint256 slippage) private pure {
        require(slippage <= MAX_SLIPPAGE, "ProductStore: Slippage exceeds maximum allowed");
    }

    /**
     * @notice Validate that a price is greater than zero
     * @param price Price value to validate
     * @dev Reverts if price is zero
     */
    function _validatePrice(uint256 price) private pure {
        require(price > 0, "ProductStore: Price must be greater than zero");
    }


    /**
     * @notice Check if a token is supported for payments
     * @param token Address of the token to check
     * @dev Only USDT and RCADE tokens are supported
     * @dev Reverts if token is not supported
     */
    function _checkTokenSupported(address token) private view {
        require(
            token == address(_usdtToken) || token == address(_rcadeToken),
            "ProductStore: Token not supported"
        );
    }

    /********** PAUSE/UNPAUSE FUNCTIONS **********/

    /**
     * @notice Pause the contract to prevent purchases
     * @dev Only the contract owner can pause
     * @dev When paused, purchase function will revert
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract to allow purchases
     * @dev Only the contract owner can unpause
     * @dev When unpaused, purchase function will work normally
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /********** UPGRADE FUNCTIONS **********/

    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of the new implementation contract
     * @dev Only the contract owner can authorize upgrades
     * @dev This function is called internally during upgrades
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
