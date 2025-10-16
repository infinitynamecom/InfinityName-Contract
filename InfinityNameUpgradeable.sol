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
    uint256 public subdomainPrice;
    uint256 public nextTokenId;
    uint256 public constant MAX_DOMAIN_LENGTH = 63;
    uint256 public constant MIN_DOMAIN_LENGTH = 1;
    uint256 public constant REFERRAL_FEE_PERCENT = 2500; // 25% = 2500 basis points

    // Fee recipient address - all registration fees go here
    // Mutable for operational flexibility (rotating treasury wallet)
    address payable public feeRecipient;

    string private _suffix;

    // Pull payment system for FEE_RECIPIENT (for failed transfers only)
    mapping(address => uint256) public pendingWithdrawals;

    // Mappings
    mapping(bytes32 => uint256) public domainToToken; // hash(domain + suffix) => tokenId
    mapping(uint256 => string) public tokenToDomain; // tokenId => fullDomain
    mapping(address => uint256[]) private ownerTokens; // NFT'lerin dahili takibi
    mapping(uint256 => uint256) private tokenIndex; // Hızlı silme için indeks takibi

    // Subdomain mappings
    mapping(uint256 => mapping(string => uint256)) public subdomainToToken; // parentTokenId => subdomain => tokenId
    mapping(uint256 => uint256) public tokenToParent; // tokenId => parentTokenId (0 if root domain)
    mapping(uint256 => string[]) public tokenToSubdomains; // tokenId => subdomain names array

    // Primary Domain Mappings
    mapping(address => uint256) public primaryDomain;

    // Events
    event DomainRegistered(
        address indexed owner,
        string domain,
        uint256 tokenId
    );
    event SubdomainRegistered(
        address indexed owner,
        string subdomain,
        uint256 tokenId,
        uint256 parentTokenId
    );
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event SubdomainPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event ReferralPaid(
        address indexed referrer,
        uint256 amount,
        address indexed buyer
    );
    event PendingWithdrawal(address indexed account, uint256 amount);
    event WithdrawalClaimed(address indexed account, uint256 amount);
    event RegistrationFeeCollected(address indexed recipient, uint256 amount);
    event PrimaryDomainSet(
        address indexed owner,
        uint256 tokenId,
        string domain
    );

    // Custom errors
    error InsufficientPayment();
    error DomainAlreadyRegistered();
    error InvalidDomain();
    error DomainNotFound();
    error TransferFailed();
    error InvalidParentToken();
    error SubdomainAlreadyExists();
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
        price = 210000000000000; // 0.00021 ETH
        subdomainPrice = 100000000000000; // 0.0001 ETH (1e14 wei)
        nextTokenId = 0;
        _suffix = ".up";
        feeRecipient = payable(0xf6547f77614F7dAf76e62767831d594b8a6e5e3b);
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
        if (msg.value < price) revert InsufficientPayment();
        if (!isValidDomain(domain)) revert InvalidDomain();
        if (referrer == msg.sender) revert InvalidReferrer();

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

        uint256 registrationFee = price - referralFee;

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
            (bool referralSuccess, ) = referrer.call{value: referralFee}("");
            if (referralSuccess) {
                emit ReferralPaid(referrer, referralFee, msg.sender);
            } else {
                pendingWithdrawals[feeRecipient] += referralFee;
                emit PendingWithdrawal(feeRecipient, referralFee);
            }
        }

        if (msg.value > price) {
            (bool success, ) = msg.sender.call{value: msg.value - price}("");
            if (!success) revert TransferFailed();
        }
    }

    function registerSubdomain(
        string calldata subdomain,
        uint256 parentTokenId,
        address referrer
    ) external payable whenNotPaused nonReentrant {
        if (msg.value < subdomainPrice) revert InsufficientPayment();
        if (!isValidDomain(subdomain)) revert InvalidDomain();
        if (_ownerOf(parentTokenId) == address(0)) revert InvalidParentToken();
        if (referrer == msg.sender) revert InvalidReferrer();

        if (subdomainToToken[parentTokenId][subdomain] != 0)
            revert SubdomainAlreadyExists();

        nextTokenId++;
        uint256 tokenId = nextTokenId;

        string memory parentDomain = tokenToDomain[parentTokenId];
        string memory fullSubdomain = string.concat(
            subdomain,
            ".",
            parentDomain
        );

        subdomainToToken[parentTokenId][subdomain] = tokenId;
        tokenToDomain[tokenId] = fullSubdomain;
        tokenToParent[tokenId] = parentTokenId;
        tokenToSubdomains[parentTokenId].push(subdomain);

        bytes32 subdomainHash = keccak256(abi.encodePacked(fullSubdomain));
        domainToToken[subdomainHash] = tokenId;

        uint256 referralFee = 0;
        if (referrer != address(0)) {
            referralFee = (subdomainPrice * REFERRAL_FEE_PERCENT) / 10000;
        }

        uint256 registrationFee = subdomainPrice - referralFee;

        (bool feeSuccess, ) = feeRecipient.call{value: registrationFee}("");
        if (feeSuccess) {
            emit RegistrationFeeCollected(feeRecipient, registrationFee);
        } else {
            pendingWithdrawals[feeRecipient] += registrationFee;
            emit PendingWithdrawal(feeRecipient, registrationFee);
        }

        _safeMint(msg.sender, tokenId);

        emit SubdomainRegistered(
            msg.sender,
            fullSubdomain,
            tokenId,
            parentTokenId
        );

        if (referrer != address(0) && referralFee > 0) {
            (bool referralSuccess, ) = referrer.call{value: referralFee}("");
            if (referralSuccess) {
                emit ReferralPaid(referrer, referralFee, msg.sender);
            } else {
                pendingWithdrawals[feeRecipient] += referralFee;
                emit PendingWithdrawal(feeRecipient, referralFee);
            }
        }

        if (msg.value > subdomainPrice) {
            (bool success, ) = msg.sender.call{
                value: msg.value - subdomainPrice
            }("");
            if (!success) revert TransferFailed();
        }
    }

    // ============ PRIMARY DOMAIN MANAGEMENT ============

    /**
     * @dev Caller'ın sahip olduğu bir token'ı ana domain olarak ayarlar.
     */
    function setPrimaryDomain(uint256 tokenId) external {
        if (_ownerOf(tokenId) == address(0)) revert DomainNotFound();
        if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        primaryDomain[msg.sender] = tokenId;
        emit PrimaryDomainSet(msg.sender, tokenId, tokenToDomain[tokenId]);
    }

    /**
     * @dev Bir adrese ait ana domainin tam alan adını döndürür.
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
        bytes32 rootDomainHash = _domainHash(domain);
        if (domainToToken[rootDomainHash] != 0) return false;

        bytes32 fullDomainHash = keccak256(abi.encodePacked(domain));
        return domainToToken[fullDomainHash] == 0;
    }

    /**
     * @dev Check if a subdomain is available
     */
    function isSubdomainAvailable(
        string calldata subdomain,
        uint256 parentTokenId
    ) external view returns (bool) {
        return subdomainToToken[parentTokenId][subdomain] == 0;
    }

    /**
     * @dev Get all subdomains of a domain
     */
    function getSubdomains(
        uint256 parentTokenId
    ) external view returns (string[] memory) {
        return tokenToSubdomains[parentTokenId];
    }

    /**
     * @dev Check if a token is a subdomain
     */
    function isSubdomain(uint256 tokenId) external view returns (bool) {
        return tokenToParent[tokenId] != 0;
    }

    /**
     * @dev Get parent token for a subdomain (0 if root)
     */
    function getParentDomain(uint256 tokenId) external view returns (uint256) {
        return tokenToParent[tokenId];
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
        uint256 parentTokenId = tokenToParent[tokenId];

        return
            InfinityNameSVG.generateTokenURI(
                tokenId,
                domain,
                parentTokenId,
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

    // ============ REFERRAL SYSTEM ============

    /**
     * @dev Get the domain suffix
     */
    function suffix() external view returns (string memory) {
        return _suffix;
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
     * @dev Set subdomain registration price (only owner)
     */
    function setSubdomainPrice(uint256 newPrice) external onlyOwner {
        uint256 oldPrice = subdomainPrice;
        subdomainPrice = newPrice;
        emit SubdomainPriceUpdated(oldPrice, newPrice);
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
    }

    /**
     * @dev Emergency transfer for specific token (only owner)
     */
    function emergencyTransfer(uint256 tokenId, address to) external onlyOwner {
        require(to != address(0), "Invalid addr");
        _transfer(ownerOf(tokenId), to, tokenId);
    }

    // ============ VIEW FUNCTIONS FOR STATS ============

    /**
     * @dev Get subdomain registration price
     */
    function getSubdomainPrice() external view returns (uint256) {
        return subdomainPrice;
    }

    /**
     * @dev Get contract statistics
     */
    function getStats()
        external
        view
        returns (
            uint256 totalSupply,
            uint256 registrationPrice,
            uint256 subdomainRegistrationPrice,
            string memory domainSuffix
        )
    {
        totalSupply = nextTokenId;
        registrationPrice = price;
        subdomainRegistrationPrice = subdomainPrice;
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
        return keccak256(abi.encodePacked(domain, _suffix));
    }

    /**
     * @dev Set the fee recipient address (only owner)
     */
    function setFeeRecipient(address payable newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid addr");
        feeRecipient = newRecipient;
    }

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[50] private __gap;
}
