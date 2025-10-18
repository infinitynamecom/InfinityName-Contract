// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./InfinityNameSVG.sol";

contract InfinityNameUpgradeable is
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using Strings for uint256;

    // State variables
    uint256 public price;
    uint256 public nextTokenId;
    uint256 public constant MAX_DOMAIN_LENGTH = 63;
    uint256 public constant MIN_DOMAIN_LENGTH = 1;
    uint256 public constant REFERRAL_FEE_PERCENT = 1250; // 12.5% = 1250 basis points
    uint256 public constant REFERRAL_DISCOUNT_PERCENT = 1250; // 12.5% = 1250 basis points

    // Fee recipient address - all registration fees go here
    // Mutable for operational flexibility (rotating treasury wallet)
    address payable public feeRecipient;

    string private _suffix;

    // Pull payment system for FEE_RECIPIENT (for failed transfers only)
    mapping(address => uint256) public pendingWithdrawals;
    
    // Pull payment system for REFERRALS (for enhanced security)
    mapping(address => uint256) public referralWithdrawals;

    // Mappings
    mapping(bytes32 => uint256) public domainToToken; // hash(domain + suffix) => tokenId
    mapping(uint256 => string) public tokenToDomain; // tokenId => fullDomain
    mapping(address => uint256[]) private ownerTokens; // Internal tracking of NFTs
    mapping(uint256 => uint256) private tokenIndex; // Index tracking for fast deletion


    // Primary Domain Mappings
    mapping(address => uint256) public primaryDomain;

    // Events
    event DomainRegistered(
        address indexed owner,
        string domain,
        uint256 tokenId
    );
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event ReferralPaid(
        address indexed referrer,
        uint256 amount,
        address indexed buyer
    );
    event ReferralPendingWithdrawal(address indexed referrer, uint256 amount);
    event ReferralDiscountApplied(
        address indexed buyer,
        uint256 discountAmount,
        address indexed referrer
    );
    event PendingWithdrawal(address indexed account, uint256 amount);
    event WithdrawalClaimed(address indexed account, uint256 amount);
    event ReferralWithdrawal(address indexed referrer, uint256 amount);
    event RegistrationFeeCollected(address indexed recipient, uint256 amount);
    event PrimaryDomainSet(
        address indexed owner,
        uint256 tokenId,
        string domain
    );
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event EmergencyWithdrawal(address indexed owner, uint256 amount);
    event TokenSeized(address indexed from, address indexed to, uint256 indexed tokenId);
    event PrimaryDomainReset(address indexed owner, uint256 tokenId);
    event ContractInitialized(uint256 price, address feeRecipient, string suffix);

    // Custom errors
    error InsufficientPayment();
    error DomainAlreadyRegistered();
    error InvalidDomain();
    error DomainNotFound();
    error TransferFailed();
    error InvalidReferrer();
    error NotTokenOwner();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract (replaces constructor)
     */
    function initialize() public initializer {
        __ERC721_init("InfinityName", "INAME");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Original constructor logic
        price = 320000000000000; // 0.00032 ETH
        nextTokenId = 0;
        _suffix = ".up";
        feeRecipient = payable(0xf6547f77614F7dAf76e62767831d594b8a6e5e3b);
        
        emit ContractInitialized(price, feeRecipient, _suffix);
    }

    /**
     * @dev Authorize upgrade (only owner can upgrade)
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // ============ DOMAIN REGISTRATION ============

    function register(
        string calldata domain,
        address referrer
    ) external payable whenNotPaused nonReentrant {
        // ✅ FIRST referrer check (to prevent fund loss)
        if (referrer == msg.sender) revert InvalidReferrer();
        
        // ✅ THEN price calculation
        uint256 actualPrice = price;
        if (referrer != address(0)) {
            uint256 discount = (price * REFERRAL_DISCOUNT_PERCENT) / 10000;
            actualPrice = price - discount;
        }
        
        if (msg.value < actualPrice) revert InsufficientPayment();
        if (!isValidDomain(domain)) revert InvalidDomain();

        bytes32 domainHash = _domainHash(domain);
        if (domainToToken[domainHash] != 0) revert DomainAlreadyRegistered();

        nextTokenId++;
        uint256 tokenId = nextTokenId;

        string memory fullDomain = string.concat(domain, _suffix);

        domainToToken[domainHash] = tokenId;
        tokenToDomain[tokenId] = fullDomain;

        uint256 referralFee = 0;
        if (referrer != address(0)) {
            referralFee = (price * REFERRAL_FEE_PERCENT) / 10000;
        }

        uint256 registrationFee = actualPrice - referralFee;

        (bool feeSuccess, ) = feeRecipient.call{value: registrationFee}("");
        if (feeSuccess) {
            emit RegistrationFeeCollected(feeRecipient, registrationFee);
        } else {
            pendingWithdrawals[feeRecipient] += registrationFee;
            emit PendingWithdrawal(feeRecipient, registrationFee);
        }

        _safeMint(msg.sender, tokenId);

        emit DomainRegistered(msg.sender, fullDomain, tokenId);

        if (referrer != address(0) && referralFee > 0) {
            // Try instant payment with limited gas (safe from reentrancy)
            (bool success, ) = referrer.call{value: referralFee, gas: 2300}("");
            
            if (success) {
                // Success: Instant payment (99% of users)
                emit ReferralPaid(referrer, referralFee, msg.sender);
            } else {
                // Failure: Fall back to pull-payment (1% of users)
                referralWithdrawals[referrer] += referralFee;
                emit ReferralPaid(referrer, referralFee, msg.sender);
                emit ReferralPendingWithdrawal(referrer, referralFee);
            }
            
            // Emit discount event
            uint256 discountAmount = (price * REFERRAL_DISCOUNT_PERCENT) / 10000;
            emit ReferralDiscountApplied(msg.sender, discountAmount, referrer);
        }

        if (msg.value > actualPrice) {
            (bool success, ) = msg.sender.call{value: msg.value - actualPrice}("");
            if (!success) revert TransferFailed();
        }
    }


    // ============ PRIMARY DOMAIN MANAGEMENT ============

    /**
     * @dev Sets a token owned by the caller as the primary domain.
     */
    function setPrimaryDomain(uint256 tokenId) external {
        if (_ownerOf(tokenId) == address(0)) revert DomainNotFound();
        if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        primaryDomain[msg.sender] = tokenId;
        emit PrimaryDomainSet(msg.sender, tokenId, tokenToDomain[tokenId]);
    }

    /**
     * @dev Returns the full domain name of the primary domain for an address.
     */
    function getPrimaryDomain(
        address owner
    ) external view returns (string memory) {
        uint256 tokenId = primaryDomain[owner];
        if (tokenId == 0) {
            return "";
        }
        return tokenToDomain[tokenId];
    }

    // ============ DOMAIN VALIDATION & AVAILABILITY ============

    /**
     * @dev Check if a domain is available
     */
    function isAvailable(string calldata domain) external view returns (bool) {
        bytes32 domainHash = _domainHash(domain);
        return domainToToken[domainHash] == 0;
    }





    /**
     * @dev Validate domain name format
     */
    function isValidDomain(string memory domain) public pure returns (bool) {
        bytes memory domainBytes = bytes(domain);
        uint256 length = domainBytes.length;

        if (length < MIN_DOMAIN_LENGTH || length > MAX_DOMAIN_LENGTH) {
            return false;
        }

        for (uint256 i = 0; i < length; i++) {
            bytes1 char = domainBytes[i];

            if (
                !(char >= 0x61 && char <= 0x7A) &&
                !(char >= 0x30 && char <= 0x39) &&
                char != 0x2D
            ) {
                return false;
            }
        }

        if (domainBytes[0] == 0x2D || domainBytes[length - 1] == 0x2D) {
            return false;
        }

        return true;
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Get domains owned by an address
     */
    function getDomainsOf(
        address owner
    ) external view returns (string[] memory) {
        uint256[] memory tokenIds = ownerTokens[owner];
        string[] memory domains = new string[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            domains[i] = tokenToDomain[tokenIds[i]];
        }

        return domains;
    }

    /**
     * @dev Get token IDs owned by an address
     */
    function getTokenIdsOf(
        address owner
    ) external view returns (uint256[] memory) {
        return ownerTokens[owner];
    }

    /**
     * @dev Generate token URI with embedded SVG
     */
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert DomainNotFound();

        string memory domain = tokenToDomain[tokenId];

        return
            InfinityNameSVG.generateTokenURI(
                tokenId,
                domain,
                _suffix
            );
    }

    // ============ TRANSFER HOOKS & OWNER TOKEN TRACKING ============

    /**
     * @dev Hook called by _mint, _burn, and _transfer
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Reset primary domain if transferred
        if (from != address(0) && primaryDomain[from] == tokenId) {
            primaryDomain[from] = 0;
            emit PrimaryDomainReset(from, tokenId);
        }

        // Update owner tokens tracking
        if (from != address(0)) {
            _removeTokenFromOwnerList(from, tokenId);
        }

        if (to != address(0)) {
            ownerTokens[to].push(tokenId);
            tokenIndex[tokenId] = ownerTokens[to].length - 1;
        }

        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Remove token from owner's list
     */
    function _removeTokenFromOwnerList(address owner, uint256 tokenId) private {
        uint256[] storage tokens = ownerTokens[owner];
        uint256 index = tokenIndex[tokenId];

        if (tokens.length == 0) return;
        if (!(index < tokens.length && tokens[index] == tokenId)) {
            uint256 found = type(uint256).max;
            for (uint256 i = 0; i < tokens.length; i++) {
                if (tokens[i] == tokenId) {
                    found = i;
                    break;
                }
            }
            if (found == type(uint256).max) return;
            index = found;
        }

        uint256 lastIndex = tokens.length - 1;

        if (index != lastIndex) {
            uint256 lastTokenId = tokens[lastIndex];
            tokens[index] = lastTokenId;
            tokenIndex[lastTokenId] = index;
        }

        tokens.pop();
        delete tokenIndex[tokenId];
    }

    // ============ PULL PAYMENT SYSTEM ============

    /**
     * @dev Withdraw pending payments (feeRecipient only)
     */
    function withdrawPendingPayments() external nonReentrant {
        require(msg.sender == feeRecipient, "Not feeRecipient");

        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No funds");

        pendingWithdrawals[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit WithdrawalClaimed(msg.sender, amount);
    }

    /**
     * @dev Check pending withdrawal amount for feeRecipient
     */
    function getPendingWithdrawal(
        address account
    ) external view returns (uint256) {
        if (account == feeRecipient) {
            return pendingWithdrawals[account];
        }
        return 0;
    }

    /**
     * @dev Check referral withdrawal amount for an address
     */
    function getReferralWithdrawal(address referrer) external view returns (uint256) {
        return referralWithdrawals[referrer];
    }

    /**
     * @dev Withdraw referral rewards (pull payment pattern for enhanced security)
     */
    function claimReferralReward() external nonReentrant {
        uint256 amount = referralWithdrawals[msg.sender];
        require(amount > 0, "No referral rewards");

        referralWithdrawals[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit ReferralWithdrawal(msg.sender, amount);
    }

    // ============ REFERRAL SYSTEM ============

    /**
     * @dev Get the domain suffix
     */
    function suffix() external view returns (string memory) {
        return _suffix;
    }

    /**
     * @dev Calculate price with referral discount
     */
    function getPriceWithReferral(address referrer) external view returns (uint256) {
        if (referrer != address(0) && referrer != msg.sender) {
            uint256 discount = (price * REFERRAL_DISCOUNT_PERCENT) / 10000;
            return price - discount;
        }
        return price;
    }

    /**
     * @dev Get referral discount amount
     */
    function getReferralDiscount() external pure returns (uint256) {
        return REFERRAL_DISCOUNT_PERCENT;
    }

    /**
     * @dev Get referral commission percentage
     */
    function getReferralCommission() external pure returns (uint256) {
        return REFERRAL_FEE_PERCENT;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Set registration price (only owner)
     */
    function setPrice(uint256 newPrice) external onlyOwner {
        uint256 oldPrice = price;
        price = newPrice;
        emit PriceUpdated(oldPrice, newPrice);
    }


    /**
     * @dev Pause contract (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause contract (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Withdraw contract earnings (only owner) - for emergency situations
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance");

        (bool success, ) = owner().call{value: balance}("");
        if (!success) revert TransferFailed();
        
        emit EmergencyWithdrawal(owner(), balance);
    }

    /**
     * @dev Emergency transfer for specific token (only owner)
     */
    function emergencyTransfer(uint256 tokenId, address to) external onlyOwner {
        require(to != address(0), "Invalid addr");
        address from = ownerOf(tokenId);
        safeTransferFrom(from, to, tokenId);
        emit TokenSeized(from, to, tokenId);
    }

    // ============ VIEW FUNCTIONS FOR STATS ============


    /**
     * @dev Get contract statistics
     */
    function getStats()
        external
        view
        returns (
            uint256 totalSupply,
            uint256 registrationPrice,
            string memory domainSuffix
        )
    {
        totalSupply = nextTokenId;
        registrationPrice = price;
        domainSuffix = _suffix;
    }

    /**
     * @dev Check if contract supports interface
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Fallback function to receive ETH
    receive() external payable {
        if (msg.value > 0) {
            (bool success, ) = feeRecipient.call{value: msg.value}("");
            if (success) {
                emit RegistrationFeeCollected(feeRecipient, msg.value);
            } else {
                pendingWithdrawals[feeRecipient] += msg.value;
                emit PendingWithdrawal(feeRecipient, msg.value);
            }
        }
    }

    // ============ INTERNAL HELPERS ============

    function _domainHash(string memory domain) internal view returns (bytes32) {
        return keccak256(abi.encode(domain, _suffix));
    }

    /**
     * @dev Set the fee recipient address (only owner)
     */
    function setFeeRecipient(address payable newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid addr");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[50] private __gap;
}
