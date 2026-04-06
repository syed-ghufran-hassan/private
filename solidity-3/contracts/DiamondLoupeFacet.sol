// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDiamondLoupe {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    /// @notice Gets all facets and their selectors.
    function facets() external view returns (Facet[] memory);

    /// @notice Gets all selectors from a specific facet address.
    function facetFunctionSelectors(address facet) external view returns (bytes4[] memory);

    /// @notice Get all facet addresses.
    function facetAddresses() external view returns (address[] memory);

    /// @notice Get the facet that supports the selector.
    function facetAddress(bytes4 selector) external view returns (address);
}

contract DiamondLoupeFacet is IDiamondLoupe {
    // This is the same DiamondStorage layout used by LibDiamond
    struct FacetAddressAndSelectorPosition {
        address facetAddress;
        uint96 selectorPosition;
    }

    struct DiamondStorage {
        mapping(bytes4 => FacetAddressAndSelectorPosition) selectorToFacetAndPosition;
        mapping(address => bytes4[]) facetFunctionSelectors;
        address[] facetAddresses;
    }

    bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function facets() external view override returns (Facet[] memory facets_) {
        DiamondStorage storage ds = diamondStorage();
        uint256 numFacets = ds.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; i++) {
            address facetAddress_ = ds.facetAddresses[i];
            facets_[i].facetAddress = facetAddress_;
            facets_[i].functionSelectors = ds.facetFunctionSelectors[facetAddress_];
        }
    }

    function facetFunctionSelectors(address facet) external view override returns (bytes4[] memory) {
        DiamondStorage storage ds = diamondStorage();
        return ds.facetFunctionSelectors[facet];
    }

    function facetAddresses() external view override returns (address[] memory) {
        DiamondStorage storage ds = diamondStorage();
        return ds.facetAddresses;
    }

    function facetAddress(bytes4 selector) external view override returns (address) {
        DiamondStorage storage ds = diamondStorage();
        return ds.selectorToFacetAndPosition[selector].facetAddress;
    }
}
