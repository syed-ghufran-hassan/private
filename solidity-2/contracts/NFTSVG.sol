//SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {BitMath} from "@velodrome-finance/slipstream/core/libraries/BitMath.sol";

library NFTSVG {
    using Strings for uint256;

    /* ─────────────────────────── constants ─────────────────────────── */

    // large static SVG chunks reused in generateSVGDefs()
    string constant _SVG_HEAD =
        '<svg width="290" height="500" viewBox="0 0 290 500" '
        'xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><defs>';

    string constant _SVG_STATIC_DEFS =
        '<clipPath id="corners"><rect width="290" height="500" rx="42" ry="42" /></clipPath>'
        '<path id="text-path-a" d="M40 12 H250 A28 28 0 0 1 278 40 V460 A28 28 0 0 1 250 488 H40 A28 28 0 0 1 12 460 V40 A28 28 0 0 1 40 12 z" />'
        '<path id="minimap" d="M234 444C234 457.949 242.21 463 253 463" />'
        '<filter id="top-region-blur"><feGaussianBlur in="SourceGraphic" stdDeviation="24" /></filter>'
        '<linearGradient id="grad-up" x1="1" x2="0" y1="1" y2="0"><stop offset="0.0" stop-color="white" stop-opacity="1" /><stop offset=".9" stop-color="white" stop-opacity="0" /></linearGradient>'
        '<linearGradient id="grad-down" x1="0" x2="1" y1="0" y2="1"><stop offset="0.0" stop-color="white" stop-opacity="1" /><stop offset="0.9" stop-color="white" stop-opacity="0" /></linearGradient>'
        '<mask id="fade-up" maskContentUnits="objectBoundingBox"><rect width="1" height="1" fill="url(#grad-up)" /></mask>'
        '<mask id="fade-down" maskContentUnits="objectBoundingBox"><rect width="1" height="1" fill="url(#grad-down)" /></mask>'
        '<mask id="none" maskContentUnits="objectBoundingBox"><rect width="1" height="1" fill="white" /></mask>'
        '<linearGradient id="grad-symbol"><stop offset="0.7" stop-color="white" stop-opacity="1" /><stop offset=".95" stop-color="white" stop-opacity="0" /></linearGradient>'
        '<mask id="fade-symbol" maskContentUnits="userSpaceOnUse"><rect width="290px" height="200px" fill="url(#grad-symbol)" /></mask></defs>';

    string constant _SVG_AFTER_DEFS =
        '<g clip-path="url(#corners)"><rect fill="';
    string constant _SVG_AFTER_DEFS_2 =
        '" x="0" y="0" width="290" height="500" />'
        '<rect style="filter:url(#f1)" x="0" y="0" width="290" height="500" />'
        '<g style="filter:url(#top-region-blur);transform:scale(1.5);transform-origin:center top;">'
        '<rect fill="none" x="0" y="0" width="290" height="500" />'
        '<ellipse cx="50%" cy="0" rx="180" ry="120" fill="#000" opacity="0.85"/></g>'
        '<rect x="0" y="0" width="290" height="500" rx="42" ry="42" fill="none" stroke="rgba(255,255,255,0.2)"/></g>';

    // Constants outside the function (can be at contract level)
    string constant TEXT_STYLE =
        ' fill="white" font-family="\'Courier New\', monospace" font-size="10px"';
    string constant ANIMATE =
        '<animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s" repeatCount="indefinite" />';
    string constant TEXT_OPEN = '<text text-rendering="optimizeSpeed">';
    string constant TEXT_CLOSE = "</text>";
    string constant TEXT_PATH_OPEN_1 = '<textPath startOffset="-100%"';
    string constant TEXT_PATH_OPEN_2 = '<textPath startOffset="0%"';
    string constant TEXT_PATH_OPEN_3 = '<textPath startOffset="50%"';
    string constant TEXT_PATH_OPEN_4 = '<textPath startOffset="-50%"';
    string constant XLINK = ' xlink:href="#text-path-a">';
    string constant TEXT_PATH_CLOSE = "</textPath>";
    /* ───────────────────────────── structs ─────────────────────────── */

    struct SVGParams {
        uint256 tokenId;
        string tokenName;
        string tokenSymbol;
        string owner;
        string lockedTokenAddress;
        address lockManagerAddress;
        string lockBoost;
        uint256 lockedAmount;
        string lockRemaining;
        bool isLocked;
        uint256 lockShares;
        string color0;
        string color1;
        string color2;
        string color3;
        string x1;
        string y1;
        string x2;
        string y2;
        string x3;
        string y3;
    }

    /* ────────────────────── public entry  ───────────────── */

    function generateSVG(
        SVGParams memory params
    ) external pure returns (string memory) {
        return
            string(
                string.concat(
                    generateSVGDefs(params),
                    generateSVGBorderText(
                        params.lockedTokenAddress,
                        params.owner,
                        params.tokenSymbol
                    ),
                    generateSVGCardMantle(params.tokenSymbol, params.lockBoost),
                    generateSvgLock(params.isLocked),
                    generateSVGPositionDataAndLocationLogo(
                        params.tokenId.toString(),
                        params.lockedAmount,
                        params.lockRemaining,
                        params.lockShares
                    ),
                    generateSVGRareSparkle(
                        params.tokenId,
                        params.lockManagerAddress
                    ),
                    "</svg>"
                )
            );
    }

    /* ──────────────────────── helper builders ─────────────────────── */

    function _rectImg(
        string memory color
    ) private pure returns (string memory) {
        return
            string(
                string.concat(
                    "<svg width='290' height='500' viewBox='0 0 290 500' xmlns='http://www.w3.org/2000/svg'><rect width='290' height='500' fill='#",
                    color,
                    "'/></svg>"
                )
            );
    }

    function _circleImg(
        string memory cx,
        string memory cy,
        string memory r,
        string memory color
    ) private pure returns (string memory) {
        return
            string(
                string.concat(
                    "<svg width='290' height='500' viewBox='0 0 290 500' xmlns='http://www.w3.org/2000/svg'><circle cx='",
                    cx,
                    "' cy='",
                    cy,
                    "' r='",
                    r,
                    "' fill='#",
                    color,
                    "'/></svg>"
                )
            );
    }

    function _feImg(
        string memory id,
        string memory svgData
    ) private pure returns (string memory) {
        return
            string(
                string.concat(
                    '<feImage result="',
                    id,
                    '" xlink:href="data:image/svg+xml;base64,',
                    Base64.encode(bytes(svgData)),
                    '"/>'
                )
            );
    }

    function generateSVGDefs(
        SVGParams memory params
    ) private pure returns (string memory out) {
        // build individual image layers
        string memory img0 = _feImg("p0", _rectImg(params.color0));
        string memory img1 = _feImg(
            "p1",
            _circleImg(params.x1, params.y1, "120", params.color1)
        );
        string memory img2 = _feImg(
            "p2",
            _circleImg(params.x2, params.y2, "120", params.color2)
        );
        string memory img3 = _feImg(
            "p3",
            _circleImg(params.x3, params.y3, "100", params.color3)
        );

        // blend chain fixed once
        string memory blends = '<feBlend mode="overlay" in="p0" in2="p1"/>'
        '<feBlend mode="exclusion" in2="p2"/>'
        '<feBlend mode="overlay" in2="p3" result="blendOut"/>'
        '<feGaussianBlur in="blendOut" stdDeviation="42"/>';

        out = string(string.concat(_SVG_HEAD, '<filter id="f1">', img0));

        out = string(
            string.concat(
                out,
                img1,
                img2,
                img3,
                blends,
                "</filter>",
                _SVG_STATIC_DEFS,
                _SVG_AFTER_DEFS,
                params.color0,
                _SVG_AFTER_DEFS_2
            )
        );
    }

    function buildOwnerTextPath(
        string memory ownerText
    ) internal pure returns (string memory result) {
        result = string.concat(
            TEXT_PATH_OPEN_1,
            TEXT_STYLE,
            XLINK,
            ownerText,
            ANIMATE,
            TEXT_PATH_CLOSE
        );
        return
            string.concat(
                result,
                TEXT_PATH_OPEN_2,
                TEXT_STYLE,
                XLINK,
                ownerText,
                ANIMATE,
                TEXT_PATH_CLOSE
            );
    }

    function buildSymbolTextPath(
        string memory symbolText
    ) internal pure returns (string memory result) {
        result = string.concat(
            TEXT_PATH_OPEN_3,
            TEXT_STYLE,
            XLINK,
            symbolText,
            ANIMATE,
            TEXT_PATH_CLOSE
        );
        return
            string.concat(
                result,
                TEXT_PATH_OPEN_4,
                TEXT_STYLE,
                XLINK,
                symbolText,
                ANIMATE,
                TEXT_PATH_CLOSE
            );
    }

    function generateSVGBorderText(
        string memory tokenAddress,
        string memory owner,
        string memory tokenSymbol
    ) internal pure returns (string memory svg) {
        string memory ownerText = string.concat(owner, unicode" - OWNER");
        string memory symbolText = string.concat(
            tokenAddress,
            unicode" • ",
            tokenSymbol
        );

        svg = string.concat(
            TEXT_OPEN,
            buildOwnerTextPath(ownerText),
            buildSymbolTextPath(symbolText),
            TEXT_CLOSE
        );
    }

    function generateSVGCardMantle(
        string memory tokenSymbol,
        string memory lockDuration
    ) private pure returns (string memory svg) {
        svg = string(
            string.concat(
                '<g mask="url(#fade-symbol)"><rect fill="none" x="0px" y="0px" width="290px" height="200px" /> <text y="70px" x="32px" fill="white" font-family="\'Courier New\', monospace" font-weight="200" font-size="36px">',
                tokenSymbol,
                '</text><text y="115px" x="32px" fill="white" font-family="\'Courier New\', monospace" font-weight="200" font-size="36px">',
                lockDuration,
                "</text></g>",
                '<rect x="16" y="16" width="258" height="468" rx="26" ry="26" fill="rgba(0,0,0,0)" stroke="rgba(255,255,255,0.2)" />'
            )
        );
    }

    function generateSvgLock(
        bool isLocked
    ) private pure returns (string memory) {
        return
            isLocked
                ? string.concat(
                    '<g id="XMLID_509_" transform="translate(71.5,151.5) scale(0.5)" fill="white">',
                    '<path id="XMLID_510_" d="M65,330h200c8.284,0,15-6.716,15-15V145c0-8.284-6.716-15-15-15h-15V85c0-46.869-38.131-85-85-85',
                    "S80,38.131,80,85v45H65c-8.284,0-15,6.716-15,15v170C50,323.284,56.716,330,65,330z M180,234.986V255c0,8.284-6.716,15-15,15",
                    "s-15-6.716-15-15v-20.014c-6.068-4.565-10-11.824-10-19.986c0-13.785,11.215-25,25-25s25,11.215,25,25",
                    'C190,223.162,186.068,230.421,180,234.986z M110,85c0-30.327,24.673-55,55-55s55,24.673,55,55v45H110V85z"/>',
                    "</g>"
                )
                : string.concat(
                    '<g id="XMLID_516_" transform="translate(46.5,151.5) scale(0.5)" fill="white">',
                    '<path id="XMLID_517_" d="M15,160c8.284,0,15-6.716,15-15V85c0-30.327,24.673-55,55-55c30.327,0,55,24.673,55,55v45h-25',
                    "c-8.284,0-15,6.716-15,15v170c0,8.284,6.716,15,15,15h200c8.284,0,15-6.716,15-15V145c0-8.284-6.716-15-15-15H170V85",
                    'c0-46.869-38.131-85-85-85S0,38.131,0,85v60C0,153.284,6.716,160,15,160z"/>',
                    "</g>"
                );
    }

    function generateSVGPositionDataAndLocationLogo(
        string memory tokenId,
        uint256 lockedAmount,
        string memory lockRemaining,
        uint256 lockShares
    ) private pure returns (string memory svg) {
        string memory lockedAmountStr = lockedAmount.toString();
        string memory lockSharesStr = lockShares.toString();
        uint256 str1length = bytes(tokenId).length + 4;
        uint256 str2length = bytes(lockedAmountStr).length + 8;
        uint256 str3length = bytes(lockSharesStr).length + 13;
        uint256 str4length = bytes(lockRemaining).length + 12;
        svg = string(
            string.concat(
                ' <g style="transform:translate(29px, 354px)">',
                '<rect width="',
                uint256(7 * (str1length + 4)).toString(),
                'px" height="26px" rx="8px" ry="8px" fill="rgba(0,0,0,0.6)" />',
                '<text x="12px" y="17px" font-family="\'Courier New\', monospace" font-size="12px" fill="white"><tspan fill="rgba(255,255,255,0.6)">ID: </tspan>',
                tokenId,
                "</text></g>",
                ' <g style="transform:translate(29px, 384px)">',
                '<rect width="',
                uint256(7 * (str2length + 4)).toString(),
                'px" height="26px" rx="8px" ry="8px" fill="rgba(0,0,0,0.6)" />',
                '<text x="12px" y="17px" font-family="\'Courier New\', monospace" font-size="12px" fill="white"><tspan fill="rgba(255,255,255,0.6)">Amount: </tspan>',
                lockedAmountStr
            )
        );
        svg = string(
            string.concat(
                svg,
                "</text></g>",
                ' <g style="transform:translate(29px, 414px)">',
                '<rect width="',
                uint256(7 * (str4length + 4)).toString(),
                'px" height="26px" rx="8px" ry="8px" fill="rgba(0,0,0,0.6)" />',
                '<text x="12px" y="17px" font-family="\'Courier New\', monospace" font-size="12px" fill="white"><tspan fill="rgba(255,255,255,0.6)">Days Left: </tspan>',
                lockRemaining,
                "</text></g>"
                ' <g style="transform:translate(29px, 444px)">',
                '<rect width="'
            )
        );
        svg = string(
            string.concat(
                svg,
                uint256(7 * (str3length + 4)).toString(),
                'px" height="26px" rx="8px" ry="8px" fill="rgba(0,0,0,0.6)" />',
                '<text x="12px" y="17px" font-family="\'Courier New\', monospace" font-size="12px" fill="white"><tspan fill="rgba(255,255,255,0.6)">Lock Shares: </tspan>',
                lockSharesStr,
                "</text></g>"
                '<g style="transform:translate(226px, 470px) scale(0.0043, -0.0043)" fill="#ffffff">',
                '<path d="M1810 8308 c-446 -42 -867 -236 -1197 -552 -341 -326 -555 -775 -603 -1265 -14 -142 -14 -4521 0 -4662 61 -620 379 -1155 884 -1490 277 -184 605 -300 927 -329 139 -12 4539 -12 4678 0 148 13 295 45 451 97 757 251 1281 915 1360 1722 14 141 14 4521 0 4662 -49 505 -279 973 -638 1299 -335 304 -732 478 -1182 519 -143 14 -4540 12 -4680 -1z m3017 -2051 c149 -43 196 -55 243 -62 185 -27 445 -81 513 -107 51 -19 139 -83 173 -127 37 -45 179 -262 224 -341 23 -41 51 -88 61 -105 10 -16 26 -43 35 -60 9 -16 46 -74 83 -128 36 -54 71 -105 76 -114 6 -9 15 -24 22 -32 87 -114 157 -188 219 -233 24 -17 42 -33 40 -35 -13 -13 -144 -31 -226 -31 -249 -1 -564 139 -927 410 -51 38 -95 73 -98 78 -3 6 -14 14 -23 19 -16 8 -17 -2 -17 -133 l0 -143 -35 -45 c-19 -25 -49 -53 -65 -62 -45 -25 -124 -105 -131 -133 -9 -34 4 -124 22 -150 8 -13 12 -23 9 -23 -4 0 195 -407 216 -440 5 -8 13 -24 18 -35 33 -72 145 -307 163 -340 12 -22 50 -74 86 -115 109 -128 138 -208 103 -283 -37 -80 -66 -100 -293 -213 -75 -37 -135 -71 -133 -75 4 -6 68 9 125 29 8 3 17 6 20 7 3 1 19 7 35 14 17 8 39 17 50 21 66 23 185 90 224 126 39 37 48 41 61 29 23 -21 66 -36 180 -61 100 -22 119 -23 405 -20 165 2 338 9 385 14 172 21 256 29 430 38 l115 6 43 -31 c32 -24 42 -38 42 -59 0 -96 -154 -265 -370 -406 -25 -17 -54 -38 -65 -47 -27 -24 -274 -163 -355 -201 -92 -43 -249 -107 -290 -120 -19 -5 -39 -13 -45 -16 -5 -4 -19 -8 -29 -9 -11 -2 -24 -7 -30 -12 -6 -5 -27 -12 -46 -16 -19 -4 -39 -11 -45 -15 -5 -4 -21 -10 -35 -13 -14 -3 -56 -15 -95 -27 -38 -11 -79 -23 -89 -25 -10 -3 -33 -9 -50 -14 -17 -6 -48 -12 -70 -16 -21 -3 -42 -8 -47 -11 -5 -3 -18 -7 -29 -10 -11 -2 -28 -6 -37 -8 -10 -3 -65 -14 -123 -26 -58 -11 -123 -29 -145 -39 -22 -11 -67 -25 -100 -31 -33 -7 -67 -16 -76 -21 -8 -4 -46 -9 -83 -11 -37 -1 -70 -7 -73 -11 -3 -5 -26 -8 -52 -7 -25 1 -48 1 -51 1 -3 -1 -180 -2 -395 -3 -349 -1 -454 4 -630 27 -16 2 -50 7 -75 10 -25 3 -61 8 -80 12 -19 3 -48 7 -65 9 -16 2 -55 8 -85 14 -30 5 -91 17 -135 25 -44 8 -120 25 -170 36 -49 11 -101 22 -115 24 -70 11 -229 47 -475 110 -204 53 -253 65 -375 95 -25 6 -52 13 -60 17 -18 8 -12 6 -85 27 -33 9 -71 22 -85 27 -14 5 -34 11 -45 14 -11 2 -58 16 -105 31 -119 37 -281 85 -305 89 -11 3 -42 9 -70 15 -27 5 -75 15 -105 22 -56 11 -296 17 -359 8 -56 -8 -48 16 31 93 57 56 94 82 168 118 192 94 439 166 785 228 94 17 188 36 210 41 22 6 58 12 80 15 201 23 333 56 400 100 81 53 85 60 88 162 3 106 4 109 157 266 113 118 187 214 226 294 15 32 29 60 29 63 1 3 9 23 19 45 10 22 34 90 53 150 19 61 37 117 40 125 3 8 7 22 9 30 18 87 65 300 71 320 35 109 127 202 341 344 88 58 168 109 178 113 11 3 35 16 54 28 19 11 76 39 125 60 50 21 94 42 99 47 6 4 16 8 22 8 7 0 25 5 41 12 33 13 23 10 136 37 48 12 91 21 95 21 9 -1 -41 -39 -51 -40 -18 0 -145 -65 -216 -110 -151 -94 -379 -265 -436 -326 -11 -12 -36 -40 -57 -61 -20 -22 -48 -67 -63 -99 -26 -56 -76 -241 -90 -329 -3 -22 -10 -56 -15 -75 -13 -49 -21 -97 -25 -151 -7 -92 61 -138 358 -242 48 -17 86 -35 84 -40 -7 -23 -95 -34 -303 -40 -120 -4 -237 -12 -258 -18 -41 -11 -96 -60 -96 -85 0 -26 59 -80 117 -106 66 -30 145 -63 153 -64 8 -1 40 -14 98 -40 29 -13 53 -22 55 -21 1 1 23 -13 49 -31 56 -39 70 -59 57 -85 -17 -30 -54 -38 -127 -26 -37 6 -87 13 -112 16 -55 6 -173 24 -346 54 -73 12 -143 19 -157 15 -30 -7 -57 -32 -57 -51 0 -16 50 -78 58 -71 3 3 10 2 16 -3 6 -5 27 -13 46 -19 19 -6 80 -27 135 -47 377 -138 666 -194 991 -194 185 1 313 15 444 48 122 31 372 112 395 127 11 8 26 14 35 14 17 0 165 71 193 92 16 12 14 17 -22 78 -22 36 -45 71 -51 78 -20 23 -131 12 -260 -27 -83 -24 -279 -70 -325 -76 -27 -3 -61 -8 -75 -11 -14 -2 -44 -7 -68 -9 -23 -2 -47 -7 -51 -10 -5 -3 -86 -8 -180 -11 -147 -6 -177 -5 -215 10 -82 31 -67 56 44 76 36 6 97 22 135 34 39 13 115 37 170 55 248 79 382 147 461 233 54 59 60 71 67 144 8 73 -3 105 -94 299 -18 39 -34 76 -35 84 -1 7 -8 27 -15 43 -9 21 -16 27 -28 22 -26 -12 -139 -13 -174 -1 -17 5 -46 16 -64 24 -17 7 -51 15 -75 18 -36 4 -252 15 -310 16 -18 0 -36 18 -21 20 4 0 17 2 28 4 11 2 36 5 55 8 53 7 122 27 148 43 12 8 22 11 22 7 0 -5 4 -3 8 2 10 14 60 32 165 60 138 37 149 57 55 104 -34 17 -79 34 -100 38 -21 3 -41 10 -44 15 -4 7 75 51 96 53 10 1 138 80 185 115 46 35 117 116 136 157 23 51 56 207 58 278 1 65 12 215 17 238 12 63 37 82 86 65 55 -19 148 -80 257 -168 57 -47 115 -94 130 -105 15 -11 38 -31 52 -43 23 -23 136 -107 297 -221 80 -56 256 -151 282 -151 8 0 -17 33 -56 73 -39 39 -79 84 -90 98 -10 14 -38 50 -62 80 -23 30 -46 59 -50 64 -4 6 -26 35 -49 65 -22 30 -49 69 -60 87 -25 44 -162 244 -182 267 -35 40 -140 73 -296 92 -22 3 -51 7 -65 10 -14 3 -83 9 -155 13 -149 9 -192 23 -267 90 -25 22 -55 41 -66 41 -13 0 -44 -27 -84 -72 -90 -104 -203 -214 -267 -261 -31 -23 -64 -48 -74 -57 -9 -9 -30 -23 -45 -31 -15 -8 -59 -35 -99 -61 -40 -27 -76 -48 -79 -48 -4 0 -41 -20 -83 -44 -195 -112 -401 -218 -401 -207 0 6 14 18 30 28 17 9 30 20 30 24 0 4 13 15 29 26 142 90 602 545 746 738 65 86 88 108 145 133 79 36 118 36 247 -1z"/>',
                '<path d="M2697 3265 c-32 -8 -68 -17 -80 -19 -12 -3 -33 -8 -47 -11 -14 -3 -43 -10 -65 -14 -306 -67 -388 -85 -495 -110 -147 -34 -292 -75 -317 -90 -16 -9 -14 -11 12 -12 93 -4 216 -19 365 -44 46 -8 240 -45 265 -51 11 -3 40 -9 65 -13 25 -5 79 -16 120 -26 41 -9 86 -19 100 -21 14 -3 32 -7 40 -10 8 -3 26 -8 39 -10 14 -3 68 -16 120 -30 53 -14 106 -27 117 -29 12 -3 75 -19 140 -36 66 -16 127 -32 137 -34 10 -2 27 -7 37 -10 10 -3 29 -8 42 -11 34 -8 83 -20 178 -44 47 -12 95 -24 108 -26 12 -2 61 -14 109 -25 48 -11 110 -25 137 -29 78 -14 107 -19 156 -30 25 -5 70 -12 101 -15 31 -3 65 -7 75 -9 110 -21 575 -29 699 -13 214 28 347 54 545 107 63 17 126 33 140 36 14 3 32 8 40 11 8 4 17 7 20 7 9 2 94 28 199 62 57 19 109 34 115 34 6 0 23 6 37 14 21 11 63 24 84 27 2 0 28 9 57 20 29 11 78 28 108 39 30 10 69 24 85 31 17 7 35 13 41 14 6 2 27 9 45 18 19 8 54 22 79 32 25 10 70 30 100 44 30 13 58 24 63 23 4 -1 7 3 7 10 0 6 3 9 6 5 6 -6 128 56 155 79 8 8 19 14 24 14 12 0 84 48 118 79 32 29 34 42 8 58 -25 16 -79 13 -386 -22 -37 -4 -85 -11 -195 -26 -47 -7 -199 -13 -338 -14 -236 -2 -254 -3 -275 -22 -44 -39 -148 -88 -232 -109 -16 -4 -34 -8 -40 -10 -41 -10 -159 -33 -200 -38 -27 -4 -95 -13 -150 -21 -260 -37 -564 -41 -840 -10 -22 3 -62 7 -90 10 -27 3 -106 15 -175 26 -69 11 -136 22 -150 24 -36 6 -162 33 -255 55 -44 11 -138 33 -210 50 -149 35 -209 51 -315 80 -81 22 -98 27 -132 36 -55 13 -195 13 -251 -1z"/>'
                "</g>"
            )
        );
    }

    function generateSVGRareSparkle(
        uint256 tokenId,
        address poolAddress
    ) private pure returns (string memory svg) {
        if (isRare(tokenId, poolAddress)) {
            svg = string(
                string.concat(
                    '<g style="transform:translate(226px, 392px)"><rect width="36px" height="36px" rx="8px" ry="8px" fill="none" stroke="rgba(255,255,255,0.2)" />',
                    '<g><path style="transform:translate(6px,6px)" d="M12 0L12.6522 9.56587L18 1.6077L13.7819 10.2181L22.3923 6L14.4341 ',
                    "11.3478L24 12L14.4341 12.6522L22.3923 18L13.7819 13.7819L18 22.3923L12.6522 14.4341L12 24L11.3478 14.4341L6 22.39",
                    '23L10.2181 13.7819L1.6077 18L9.56587 12.6522L0 12L9.56587 11.3478L1.6077 6L10.2181 10.2181L6 1.6077L11.3478 9.56587L12 0Z" fill="white" />',
                    '<animateTransform attributeName="transform" type="rotate" from="0 18 18" to="360 18 18" dur="10s" repeatCount="indefinite"/></g></g>'
                )
            );
        } else {
            svg = "";
        }
    }

    function isRare(
        uint256 tokenId,
        address poolAddress
    ) internal pure returns (bool) {
        bytes32 h = keccak256(abi.encodePacked(tokenId, poolAddress));
        return
            uint256(h) <
            type(uint256).max / (1 + BitMath.mostSignificantBit(tokenId) * 2);
    }
}
