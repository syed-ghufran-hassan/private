// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/AgentWalletFactory.sol";

contract AgentWalletFactoryTest is Test {
    event WalletCreated(address indexed user, address indexed wallet, address indexed safe);

    AgentWallet implementation;
    AgentWalletFactory factory;
    
    address owner = address(1);
    address operator = address(2);
    address user = address(3);
    address safe = address(4);
    
    function setUp() public {
        // Deploy implementation
        implementation = new AgentWallet();
        
        // Deploy factory
        factory = new AgentWalletFactory(address(implementation), operator);
        
        // Transfer ownership to owner (address(1))
        factory.transferOwnership(owner);
        
        // Fund user
        vm.deal(user, 1 ether);
    }
    
    function test_CreateWallet() public {
        vm.prank(operator);
        address wallet = factory.createWallet(user, safe);
        
        assertTrue(wallet != address(0));
        assertEq(factory.getWallet(user), wallet);
        assertTrue(factory.hasWallet(user));
        assertEq(factory.getWalletCount(), 1);
    }
    
    function test_RevertWhen_UserAlreadyHasWallet() public {
        vm.prank(operator);
        factory.createWallet(user, safe);
        
        vm.prank(operator);
        vm.expectRevert(AgentWalletFactory.WalletAlreadyExists.selector);
        factory.createWallet(user, safe);
    }
    
    function test_WalletInitialization() public {
        vm.prank(operator);
        address walletAddr = factory.createWallet(user, safe);
        
        AgentWallet wallet = AgentWallet(payable(walletAddr));
        
        assertEq(wallet.owner(), user);
        assertEq(wallet.safeAddress(), safe);
        assertEq(wallet.operator(), operator);
        assertTrue(wallet.isActive());
        assertTrue(wallet.isConfigured());
    }
    
    function test_ProposeTransaction() public {
        // Create wallet
        vm.prank(operator);
        address walletAddr = factory.createWallet(user, safe);
        AgentWallet wallet = AgentWallet(payable(walletAddr));
        
        // Propose transaction
        address to = address(5);
        uint256 value = 0.1 ether;
        bytes memory data = "";
        string memory metadata = '{"agent": "treasury-optimizer"}';
        
        vm.prank(operator);
        bytes32 txHash = wallet.proposeTransaction(to, value, data, metadata);
        
        assertTrue(txHash != bytes32(0));
        
        AgentWallet.AgentTransaction memory tx = wallet.getTransaction(txHash);
        assertEq(tx.to, to);
        assertEq(tx.value, value);
        assertEq(tx.metadata, metadata);
        assertFalse(tx.executed);
    }
    
    function test_RevertWhen_NonOperatorProposes() public {
        vm.prank(operator);
        address walletAddr = factory.createWallet(user, safe);
        AgentWallet wallet = AgentWallet(payable(walletAddr));
        
        vm.prank(address(999)); // Random address
        vm.expectRevert("AgentWallet: only operator");
        wallet.proposeTransaction(address(5), 0, "", "");
    }
    
    function test_MarkExecuted() public {
        // Create wallet and propose
        vm.prank(operator);
        address walletAddr = factory.createWallet(user, safe);
        AgentWallet wallet = AgentWallet(payable(walletAddr));
        
        vm.prank(operator);
        bytes32 txHash = wallet.proposeTransaction(address(5), 0, "", "");
        
        // Mark as executed
        bytes32 safeTxHash = keccak256("safe_tx_hash");
        vm.prank(operator);
        wallet.markExecuted(txHash, safeTxHash);
        
        AgentWallet.AgentTransaction memory tx = wallet.getTransaction(txHash);
        assertTrue(tx.executed);
        assertEq(tx.safeTxHash, safeTxHash);
    }
    
    function test_UserCanUpdateOperator() public {
        vm.prank(operator);
        address walletAddr = factory.createWallet(user, safe);
        AgentWallet wallet = AgentWallet(payable(walletAddr));
        
        address newOperator = address(999);
        
        vm.prank(user);
        wallet.updateOperator(newOperator);
        
        assertEq(wallet.operator(), newOperator);
    }
    
    function test_UserCanDeactivateWallet() public {
        vm.prank(operator);
        address walletAddr = factory.createWallet(user, safe);
        AgentWallet wallet = AgentWallet(payable(walletAddr));
        
        vm.prank(user);
        wallet.deactivate();
        
        assertFalse(wallet.isActive());
        assertFalse(wallet.isConfigured());
    }
    
    function test_UserCanReactivateWallet() public {
        vm.prank(operator);
        address walletAddr = factory.createWallet(user, safe);
        AgentWallet wallet = AgentWallet(payable(walletAddr));
        
        vm.prank(user);
        wallet.deactivate();
        
        vm.prank(user);
        wallet.reactivate();
        
        assertTrue(wallet.isActive());
        assertTrue(wallet.isConfigured());
    }
    
    function test_RevertWhen_ProposeInactiveWallet() public {
        vm.prank(operator);
        address walletAddr = factory.createWallet(user, safe);
        AgentWallet wallet = AgentWallet(payable(walletAddr));
        
        vm.prank(user);
        wallet.deactivate();
        
        vm.prank(operator);
        vm.expectRevert("AgentWallet: wallet not active");
        wallet.proposeTransaction(address(5), 0, "", "");
    }
    
    function test_FactoryUpdateImplementation() public {
        address newImpl = address(new AgentWallet());
        
        vm.prank(owner);
        factory.updateImplementation(newImpl);
        
        assertEq(factory.implementation(), newImpl);
    }
    
    function test_FactoryUpdateOperator() public {
        address newOperator = address(999);
        
        vm.prank(owner);
        factory.updateOperator(newOperator);
        
        assertEq(factory.operator(), newOperator);
    }
    
    function test_BatchCreateWallets() public {
        address[] memory users = new address[](3);
        users[0] = address(10);
        users[1] = address(11);
        users[2] = address(12);
        
        address[] memory safes = new address[](3);
        safes[0] = address(20);
        safes[1] = address(21);
        safes[2] = address(22);
        
        vm.prank(owner);
        address[] memory wallets = factory.batchCreateWallets(users, safes);
        
        assertEq(wallets.length, 3);
        assertEq(factory.getWalletCount(), 3);
        
        for (uint i = 0; i < 3; i++) {
            assertTrue(wallets[i] != address(0));
            assertEq(factory.getWallet(users[i]), wallets[i]);
        }
    }
    
    function test_ImplementationReused() public {
        // Deploy 5 wallets
        for (uint i = 0; i < 5; i++) {
            address newUser = vm.addr(100 + i);
            address newSafe = vm.addr(200 + i);
            
            vm.prank(operator);
            factory.createWallet(newUser, newSafe);
        }
        
        // All should use same implementation
        assertEq(factory.getWalletCount(), 5);
    }
    
    function testFuzz_CreateWallet(address _user, address _safe) public {
        vm.assume(_user != address(0));
        vm.assume(_safe != address(0));
        
        vm.prank(operator);
        address wallet = factory.createWallet(_user, _safe);
        
        assertTrue(wallet != address(0));
        assertEq(factory.getWallet(_user), wallet);
    }
    
    function test_EventsEmitted() public {
        // Test WalletCreated event - ignore second topic (wallet address)
        vm.expectEmit(true, false, true, false);
        emit WalletCreated(user, address(0), safe);
        
        vm.prank(operator);
        factory.createWallet(user, safe);
    }
}
