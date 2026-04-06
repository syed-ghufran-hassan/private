// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

library LibDiamond {
    bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    event DiamondCut(FacetCut[] _diamondCut);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct DiamondStorage {
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
        address contractOwner;
    }

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function setContractOwner(address _newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function contractOwner() internal view returns (address) {
        return diamondStorage().contractOwner;
    }

    function enforceIsContractOwner() internal view {
        require(_msgSender() == contractOwner(), "LibDiamond: Must be contract owner");
    }

    function diamondCut(FacetCut[] calldata _diamondCuts) internal {
        DiamondStorage storage ds = diamondStorage();

        for (uint i = 0; i < _diamondCuts.length; i++) {
            FacetCutAction action = _diamondCuts[i].action;
            address facetAddress = _diamondCuts[i].facetAddress;
            bytes4[] memory selectors = _diamondCuts[i].functionSelectors;

            if (action == FacetCutAction.Add) {
                _handleAddFacet(ds, facetAddress, selectors);
            } else if (action == FacetCutAction.Replace) {
                _handleReplaceFacet(ds, facetAddress, selectors);
            } else if (action == FacetCutAction.Remove) {
                _handleRemoveFacet(ds, selectors);
            } else {
                revert("LibDiamondCut: Invalid FacetCutAction");
            }
        }

        emit DiamondCut(_diamondCuts);
    }

    function _handleAddFacet(DiamondStorage storage ds, address facetAddress, bytes4[] memory selectors) private {
        require(selectors.length > 0, "LibDiamondCut: No selectors to add");
        require(facetAddress != address(0), "LibDiamondCut: Add facet can't be address(0)");

        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[facetAddress].functionSelectors.length);

        if (selectorPosition == 0) {
            _enforceHasContractCode(facetAddress, "LibDiamondCut: New facet has no code");
            ds.facetFunctionSelectors[facetAddress].facetAddressPosition = ds.facetAddresses.length;
            ds.facetAddresses.push(facetAddress);
        }

        for (uint j = 0; j < selectors.length; j++) {
            bytes4 selector = selectors[j];
            require(
                ds.selectorToFacetAndPosition[selector].facetAddress == address(0),
                "LibDiamondCut: Can't add function that already exists"
            );

            ds.facetFunctionSelectors[facetAddress].functionSelectors.push(selector);
            ds.selectorToFacetAndPosition[selector] = FacetAddressAndPosition({
                facetAddress: facetAddress,
                functionSelectorPosition: selectorPosition
            });
            selectorPosition++;
        }
    }

    function _handleReplaceFacet(DiamondStorage storage ds, address facetAddress, bytes4[] memory selectors) private {
        require(selectors.length > 0, "LibDiamondCut: No selectors to replace");
        require(facetAddress != address(0), "LibDiamondCut: Replace facet can't be address(0)");

        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[facetAddress].functionSelectors.length);

        if (selectorPosition == 0) {
            _enforceHasContractCode(facetAddress, "LibDiamondCut: New facet has no code");
            ds.facetFunctionSelectors[facetAddress].facetAddressPosition = ds.facetAddresses.length;
            ds.facetAddresses.push(facetAddress);
        }

        for (uint j = 0; j < selectors.length; j++) {
            bytes4 selector = selectors[j];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            require(oldFacet != facetAddress, "LibDiamondCut: Can't replace with same function");
            require(oldFacet != address(0), "LibDiamondCut: Can't replace non-existent function");

            _removeFunction(ds, oldFacet, selector);

            ds.selectorToFacetAndPosition[selector] = FacetAddressAndPosition({
                facetAddress: facetAddress,
                functionSelectorPosition: selectorPosition
            });
            ds.facetFunctionSelectors[facetAddress].functionSelectors.push(selector);
            selectorPosition++;
        }
    }

    function _handleRemoveFacet(DiamondStorage storage ds, bytes4[] memory selectors) private {
        require(selectors.length > 0, "LibDiamondCut: No selectors to remove");

        for (uint j = 0; j < selectors.length; j++) {
            bytes4 selector = selectors[j];
            FacetAddressAndPosition memory oldInfo = ds.selectorToFacetAndPosition[selector];
            address oldFacetAddress = oldInfo.facetAddress;
            require(oldFacetAddress != address(0), "LibDiamondCut: Can't remove non-existent function");

            _removeFunction(ds, oldFacetAddress, selector);
        }
    }

    // 🧹 Remove helper
    function _removeFunction(DiamondStorage storage ds, address facetAddress, bytes4 selector) private {
        require(facetAddress != address(0), "LibDiamondCut: Function does not exist");

        uint256 selectorPos = ds.selectorToFacetAndPosition[selector].functionSelectorPosition;
        uint256 lastSelectorPos = ds.facetFunctionSelectors[facetAddress].functionSelectors.length - 1;

        if (selectorPos != lastSelectorPos) {
            bytes4 lastSelector = ds.facetFunctionSelectors[facetAddress].functionSelectors[lastSelectorPos];
            ds.facetFunctionSelectors[facetAddress].functionSelectors[selectorPos] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPos);
        }
        ds.facetFunctionSelectors[facetAddress].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[selector];

        if (ds.facetFunctionSelectors[facetAddress].functionSelectors.length == 0) {
            uint256 lastFacetPos = ds.facetAddresses.length - 1;
            uint256 facetPos = ds.facetFunctionSelectors[facetAddress].facetAddressPosition;

            if (facetPos != lastFacetPos) {
                address lastFacet = ds.facetAddresses[lastFacetPos];
                ds.facetAddresses[facetPos] = lastFacet;
                ds.facetFunctionSelectors[lastFacet].facetAddressPosition = facetPos;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[facetAddress].facetAddressPosition;
        }
    }

    function _enforceHasContractCode(address _contract, string memory _errorMessage) private view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        require(contractSize > 0, _errorMessage);
    }

    function _msgSender() private view returns (address) {
        return msg.sender;
    }
}
