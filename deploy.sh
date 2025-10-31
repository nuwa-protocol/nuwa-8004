#!/bin/bash
# ERC-8004 v1.0 Multi-Chain Deployment Script
# Usage: ./deploy.sh <network>
# Networks: sepolia, base_sepolia, optimism_sepolia, mode_testnet, zg_testnet, xlayer, xlayer_testnet, all

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found!${NC}"
    echo "Please create a .env file with:"
    echo "  PRIVATE_KEY=your_private_key"
    echo "  SEPOLIA_RPC_URL=..."
    echo "  BASE_SEPOLIA_RPC_URL=..."
    echo "  OPTIMISM_SEPOLIA_RPC_URL=..."
    echo "  ZG_TESTNET_RPC_URL=..."
    exit 1
fi

source .env

# Check if PRIVATE_KEY is set
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

# Helper: verify contracts on OKLink using Foundry plugin for X Layer networks
# This reads the latest broadcast file for the chain id, extracts deployed addresses,
# and runs `forge verify-contract` for each contract with the oklink verifier.
verify_oklink() {
    local chain_id=$1          # e.g., 196 or 1952
    local chain_short=$2       # e.g., XLAYER or XLAYER_TESTNET

    if [ -z "$chain_short" ]; then
        echo -e "${RED}Error: OKLink chain short name missing for chain $chain_id.${NC}"
        return 1
    fi

    # Construct verifier URL per OKLink docs
    local verifier_url="https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/${chain_short}"

    # Latest broadcast file for this chain
    local bcast_dir="broadcast/Deploy.s.sol/${chain_id}"
    local latest_json="${bcast_dir}/run-latest.json"

    if [ ! -f "$latest_json" ]; then
        echo -e "${RED}Error: broadcast file not found: ${latest_json}${NC}"
        echo -e "${YELLOW}Run deployment first so we can pick up addresses to verify.${NC}"
        return 1
    fi

    # Extract addresses by contract name from broadcast JSON
    local IDENTITY_ADDR=$(jq -r '.transactions[] | select(.contractName=="IdentityRegistry") | .contractAddress' "$latest_json")
    local REPUTATION_ADDR=$(jq -r '.transactions[] | select(.contractName=="ReputationRegistry") | .contractAddress' "$latest_json")
    local VALIDATION_ADDR=$(jq -r '.transactions[] | select(.contractName=="ValidationRegistry") | .contractAddress' "$latest_json")

    if [ -z "$IDENTITY_ADDR" ] || [ "$IDENTITY_ADDR" = "null" ]; then
        echo -e "${RED}Could not find IdentityRegistry address in ${latest_json}${NC}"
        return 1
    fi

    echo -e "${GREEN}Verifying on OKLink (${chain_short}) using ${verifier_url}${NC}"

    # IdentityRegistry has no constructor args
    echo -e "${BLUE}[1/3] Verifying IdentityRegistry at ${IDENTITY_ADDR} ...${NC}"
    forge verify-contract \
        ${IDENTITY_ADDR} \
        src/IdentityRegistry.sol:IdentityRegistry \
        --chain ${chain_id} \
        --verifier oklink \
        --verifier-url ${verifier_url} \
        --watch || true

    # Constructor args for the other two registries are the IdentityRegistry address
    local CONSTRUCTOR_ARGS
    CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" ${IDENTITY_ADDR})

    if [ -n "$REPUTATION_ADDR" ] && [ "$REPUTATION_ADDR" != "null" ]; then
        echo -e "${BLUE}[2/3] Verifying ReputationRegistry at ${REPUTATION_ADDR} ...${NC}"
        forge verify-contract \
            ${REPUTATION_ADDR} \
            src/ReputationRegistry.sol:ReputationRegistry \
            --constructor-args ${CONSTRUCTOR_ARGS} \
            --chain ${chain_id} \
            --verifier oklink \
            --verifier-url ${verifier_url} \
            --watch || true
    fi

    if [ -n "$VALIDATION_ADDR" ] && [ "$VALIDATION_ADDR" != "null" ]; then
        echo -e "${BLUE}[3/3] Verifying ValidationRegistry at ${VALIDATION_ADDR} ...${NC}"
        forge verify-contract \
            ${VALIDATION_ADDR} \
            src/ValidationRegistry.sol:ValidationRegistry \
            --constructor-args ${CONSTRUCTOR_ARGS} \
            --chain ${chain_id} \
            --verifier oklink \
            --verifier-url ${verifier_url} \
            --watch || true
    fi

    echo -e "${GREEN}OKLink verification commands submitted. Use --watch logs above or run 'forge verify-check' with your GUID if needed.${NC}"
}

# Function to deploy to a network
deploy_network() {
    local network=$1
    local rpc_var=$2
    local chain_name=$3
    local verify_flag=$4
    
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Deploying to ${chain_name}${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    # Check if RPC URL is set
    local rpc_url=$(eval echo \$$rpc_var)
    if [ -z "$rpc_url" ]; then
        echo -e "${YELLOW}Warning: ${rpc_var} not set, skipping ${chain_name}${NC}"
        return
    fi
    
    # Deploy
    echo -e "${GREEN}Deploying contracts...${NC}"
    if [ "$verify_flag" = "verify" ]; then
        forge script script/Deploy.s.sol:Deploy \
            --rpc-url $network \
            --broadcast \
            --verify \
            -vvv
    elif [ "$verify_flag" = "oklink-verify-xlayer" ]; then
        # For X Layer networks, deploy first, then verify via OKLink plugin using broadcast data
        forge script script/Deploy.s.sol:Deploy \
            --rpc-url $network \
            --broadcast \
            -vvv

        # Determine chain id and chain short name for OKLink
        local chain_id
        if [ "$network" = "xlayer" ]; then
            chain_id=196
            verify_oklink "$chain_id" "XLAYER"
        elif [ "$network" = "xlayer_testnet" ]; then
            chain_id=1952
            verify_oklink "$chain_id" "XLAYER_TESTNET"
        else
            echo -e "${YELLOW}Unknown network for oklink verification: $network${NC}"
        fi
    else
        forge script script/Deploy.s.sol:Deploy \
            --rpc-url $network \
            --broadcast \
            -vvv
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Successfully deployed to ${chain_name}!${NC}"
    else
        echo -e "${RED}❌ Deployment to ${chain_name} failed${NC}"
        return 1
    fi
}

# Parse command line argument
NETWORK=${1:-help}

case $NETWORK in
    sepolia)
        deploy_network "sepolia" "SEPOLIA_RPC_URL" "Ethereum Sepolia" "verify"
        ;;
    base_sepolia)
        deploy_network "base_sepolia" "BASE_SEPOLIA_RPC_URL" "Base Sepolia" "verify"
        ;;
    optimism_sepolia)
        deploy_network "optimism_sepolia" "OPTIMISM_SEPOLIA_RPC_URL" "Optimism Sepolia" "verify"
        ;;
    mode_testnet)
        deploy_network "mode_testnet" "MODE_TESTNET_RPC_URL" "Mode Testnet" "verify"
        ;;
    zg_testnet)
        echo -e "${YELLOW}Note: 0G testnet verification not yet supported via forge${NC}"
        deploy_network "zg_testnet" "ZG_TESTNET_RPC_URL" "0G Testnet" "no-verify"
        ;;
    xlayer)
        echo -e "${GREEN}X Layer: using OKLink plugin verification${NC}"
        deploy_network "xlayer" "XLAYER_RPC_URL" "X Layer Mainnet" "oklink-verify-xlayer"
        ;;
    xlayer_testnet)
        echo -e "${GREEN}X Layer Testnet: using OKLink plugin verification${NC}"
        deploy_network "xlayer_testnet" "XLAYER_TESTNET_RPC_URL" "X Layer Testnet" "oklink-verify-xlayer"
        ;;
    verify_xlayer)
        echo -e "${GREEN}Verify only: X Layer mainnet via OKLink${NC}"
        verify_oklink 196 "XLAYER"
        ;;
    verify_xlayer_testnet)
        echo -e "${GREEN}Verify only: X Layer testnet via OKLink${NC}"
        verify_oklink 1952 "XLAYER_TESTNET"
        ;;
    all)
        echo -e "${GREEN}Deploying to all testnets...${NC}"
        deploy_network "sepolia" "SEPOLIA_RPC_URL" "Ethereum Sepolia" "verify"
        deploy_network "base_sepolia" "BASE_SEPOLIA_RPC_URL" "Base Sepolia" "verify"
        deploy_network "optimism_sepolia" "OPTIMISM_SEPOLIA_RPC_URL" "Optimism Sepolia" "verify"
        deploy_network "mode_testnet" "MODE_TESTNET_RPC_URL" "Mode Testnet" "verify"
        deploy_network "zg_testnet" "ZG_TESTNET_RPC_URL" "0G Testnet" "no-verify"
        echo -e "${GREEN}Deploying to X Layer networks...${NC}"
        deploy_network "xlayer_testnet" "XLAYER_TESTNET_RPC_URL" "X Layer Testnet" "oklink-verify-xlayer"
        deploy_network "xlayer" "XLAYER_RPC_URL" "X Layer Mainnet" "oklink-verify-xlayer"
        echo -e "\n${GREEN}✅ All deployments complete!${NC}"
        ;;
    help|*)
        echo -e "${BLUE}ERC-8004 v1.0 Deployment Script${NC}"
        echo ""
        echo "Usage: ./deploy.sh <network>"
        echo ""
        echo "Available networks:"
        echo "  sepolia           - Ethereum Sepolia testnet"
        echo "  base_sepolia      - Base Sepolia testnet"
        echo "  optimism_sepolia  - Optimism Sepolia testnet"
        echo "  mode_testnet      - Mode Testnet"
        echo "  zg_testnet        - 0G testnet"
        echo "  xlayer_testnet    - X Layer Testnet (chainId 1952)"
        echo "  xlayer            - X Layer Mainnet (chainId 196)"
        echo "  all               - Deploy to all testnets + X Layer"
        echo ""
        echo "Examples:"
        echo "  ./deploy.sh sepolia"
        echo "  ./deploy.sh xlayer_testnet"
        echo "  ./deploy.sh all"
        echo ""
        echo "Prerequisites:"
        echo "  1. Create .env file with PRIVATE_KEY and RPC URLs"
        echo "  2. Ensure deployer wallet has testnet tokens"
        echo "  3. Set block explorer API keys for verification"
        exit 0
        ;;
esac
