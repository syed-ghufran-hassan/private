-include .env

.PHONY: all test clean deploy fund help install snapshot format anvil 

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

help:
	@echo "Usage:"
	@echo "  make deploy [ARGS=...]\n    example: make deploy ARGS=\"--network sepolia\""
	@echo ""
	@echo "  make fund [ARGS=...]\n    example: make deploy ARGS=\"--network sepolia\""

all: clean remove install update build

# Clean the repo
clean  :; forge clean

# Remove modules
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

install :; forge install forge install smartcontractkit/chainlink-brownie-contracts --no-commit && forge install foundry-rs/forge-std --no-commit && forge install openzeppelin/openzeppelin-contracts --no-commit && forge install PaulRBerg/prb-math --no-commit && forge install velodrome-finance/slipstream --no-commit && forge install velodrome-finance/pool-launcher --no-commit

# Update Dependencies
update:; forge update

build:; forge build

buildf:; forge build --force

env :; source .env

sizes :; forge b --sizes

test :; forge test --rpc-url $(ETH_SEPOLIA_RPC_URL)

snapshot :; forge snapshot

format :; forge fmt

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

deploy-sepolia:
	@forge script script/DeployRaffle.s.sol:DeployRaffle --rpc-url $(SEPOLIA_RPC_URL) --account dev --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
deploy-anvil:
	@forge script script/DeployRaffle.s.sol:DeployRaffle --rpc-url $(ANVAIL_RPC_URL) --account default --broadcast

createSubscription:
	@forge script script/Interactions.s.sol:CreateSubscription $(NETWORK_ARGS)

addConsumer:
	@forge script script/Interactions.s.sol:AddConsumer $(NETWORK_ARGS)

fundSubscription:
	@forge script script/Interactions.s.sol:FundSubscription $(NETWORK_ARGS)

wallet-dev:
	@cast wallet import --interactive dev
wallet-default:
	@cast wallet import --interactive default

