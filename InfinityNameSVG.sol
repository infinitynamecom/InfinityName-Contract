// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title InfinityNameSVG
 * @dev Library for generating SVG images and metadata for InfinityName NFTs
 */
library InfinityNameSVG {
    using Strings for uint256;

    /**
     * @dev Generate complete token URI with embedded SVG
     */
    function generateTokenURI(
        uint256 tokenId,
        string memory domain,
        string memory suffix
    ) internal pure returns (string memory) {
        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        generateTokenMetadata(
                            tokenId,
                            domain,
                            suffix
                        )
                    )
                )
            );
    }

    /**
     * @dev Generate metadata JSON for token
     */
    function generateTokenMetadata(
        uint256 tokenId,
        string memory domain,
        string memory suffix
    ) internal pure returns (string memory) {
        return
            string.concat(
                '{"name":"',
                domain,
                '",',
                '"description":"InfinityName Domain NFT - owned forever, no renewals required. Decentralized domain name system.",',
                '"attributes":',
                generateAttributes(tokenId, domain, suffix),
                ",",
                '"image":"data:image/svg+xml;base64,',
                Base64.encode(bytes(generateSVG(domain))),
                '"}'
            );
    }

    /**
     * @dev Generate attributes array for metadata
     */
    function generateAttributes(
        uint256, // tokenId - unused but kept for interface consistency
        string memory domain,
        string memory suffix
    ) internal pure returns (string memory) {
        uint256 displayedLen = bytes(domain).length - bytes(suffix).length;

        return string.concat(
            '[{"trait_type":"Domain","value":"',
            domain,
            '"},',
            '{"trait_type":"Length","value":',
            displayedLen.toString(),
            "},",
            '{"trait_type":"Type","value":"Domain NFT"}]'
        );
    }

    /**
     * @dev Generate SVG image for token
     */
    function generateSVG(
        string memory domain
    ) internal pure returns (string memory) {
        return
            string.concat(
                '<svg xmlns="http://www.w3.org/2000/svg" width="500" height="500" viewBox="0 0 500 500">',
                getSVGDefs(),
                getSVGContent(domain),
                "</svg>"
            );
    }

    /**
     * @dev Generate SVG definitions section (gradients)
     */
    function getSVGDefs() internal pure returns (string memory) {
        string memory gradientStops =
            '<stop offset="0%" stop-color="#667eea"/><stop offset="100%" stop-color="#764ba2"/>';

        return
            string.concat(
                '<defs><linearGradient id="grad" x1="0%" y1="0%" x2="100%" y2="100%">',
                gradientStops,
                "</linearGradient></defs>"
            );
    }

    /**
     * @dev Generate SVG content section (shapes and text)
     */
    function getSVGContent(
        string memory domain
    ) internal pure returns (string memory) {
        string memory typeText = "Forever Owned - No Renewals";

        return
            string.concat(
                '<rect width="100%" height="100%" fill="url(#grad)"/>',
                '<circle cx="250" cy="200" r="80" fill="rgba(255,255,255,0.1)" stroke="rgba(255,255,255,0.3)" stroke-width="2"/>',
                '<path d="M 200 200 C 200 180, 220 180, 230 200 C 240 220, 260 220, 270 200 C 280 180, 300 180, 300 200 C 300 220, 280 220, 270 200 C 260 180, 240 180, 230 200 C 220 220, 200 220, 200 200 Z" fill="white" opacity="0.9"/>',
                '<text x="50%" y="65%" fill="white" font-size="20" font-weight="bold" text-anchor="middle" font-family="monospace">',
                domain,
                '</text><text x="50%" y="75%" fill="rgba(255,255,255,0.7)" font-size="12" text-anchor="middle" font-family="sans-serif">',
                typeText,
                "</text>"
            );
    }
}

