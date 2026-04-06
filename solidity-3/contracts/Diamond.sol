// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { LibDiamond } from "./libraries/LibDiamond.sol";
import { LibAdapterStorage } from "./libraries/LibAdapterStorage.sol";
import "fhevm/gateway/GatewayCaller.sol";
import { SepoliaZamaFHEVMConfig } from "fhevm/config/ZamaFHEVMConfig.sol";
import { SepoliaZamaGatewayConfig } from "fhevm/config/ZamaGatewayConfig.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract Diamond is SepoliaZamaFHEVMConfig, SepoliaZamaGatewayConfig, GatewayCaller, ReentrancyGuardTransient {
    modifier onlyCToken() {
        address[] memory aaveSupportedTokens = LibAdapterStorage.getStorage().aavePool.getReservesList();
        bool isCToken = false;
        for (uint256 i = 0; i < aaveSupportedTokens.length; i++) {
            if (LibAdapterStorage.getStorage().tokenAddressToCTokenAddress[aaveSupportedTokens[i]] == msg.sender) {
                isCToken = true;
                break;
            }
        }
        require(isCToken, "Diamond: caller is not a cToken");
        _;
    }

    constructor(address _contractOwner) {
        LibDiamond.setContractOwner(_contractOwner);
    }

    function diamondCut(LibDiamond.FacetCut[] calldata _diamondCut) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(_diamondCut);
    }

    // Find facet for function that is called and execute the
    // function if a facet is found and return any value.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();

        // get facet from function selector (which is == msg.sig)
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: Function does not exist");

        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize()) // copies the calldata into memory
            // execute function call against the relevant facet
            // note that we send in the entire calldata including the function selector
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                // delegate call failed
                revert(0, returndatasize()) // so revert
            }
            default {
                return(0, returndatasize()) // delegatecall succeeded, return any return data
            }
        }
    }

    function onUnwrap(uint256 requestId, uint256 amount) external nonReentrant onlyCToken {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();

        s.requestIdToAmount[requestId] = amount;

        for (uint256 i = requestId - 1; i > 0; i--) {
            LibAdapterStorage.RequestType rt = s.requestIdToRequestData[i].requestType;
            if (rt == LibAdapterStorage.RequestType.SUPPLY || rt == LibAdapterStorage.RequestType.REPAY) {
                s.requestIdToUnwrapRequestId[i] = requestId;
                break;
            }
        }

        emit LibAdapterStorage.OnUnwrap(requestId, amount);
    }

    receive() external payable {}
}
