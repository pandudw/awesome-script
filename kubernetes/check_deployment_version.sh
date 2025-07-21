#!/bin/bash

NAMESPACES=("${@:-default}") 
DEPLOYMENTS=("api" "worker" "web")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

echo -e "${YELLOW}🔍 Checking deployments across ${#NAMESPACES[@]} namespace(s): ${NAMESPACES[*]}${NC}"
echo "========================================================================"

for NAMESPACE in "${NAMESPACES[@]}"; do
    echo -e "\n${BLUE}🏷️  NAMESPACE: ${NAMESPACE}${NC}"
    echo "----------------------------------------"
    
    if ! all_deployments=$(kubectl get deployments -n "$NAMESPACE" -o json 2>/dev/null); then
        echo -e "${RED}❌ Failed to get deployments from namespace: ${NAMESPACE}${NC}"
        continue
    fi
    
    deployment_count=$(echo "$all_deployments" | jq '.items | length')
    if [ "$deployment_count" -eq 0 ]; then
        echo -e "${YELLOW}⚠️  No deployments found in namespace: ${NAMESPACE}${NC}"
        continue
    fi
    
    for DEPLOY in "${DEPLOYMENTS[@]}"; do
        echo -e "\n  ${GREEN}📦 Deployment: ${DEPLOY}${NC}"
        
        deployment_data=$(echo "$all_deployments" | jq -r --arg deploy "$DEPLOY" '
            .items[] | select(.metadata.name == $deploy)
        ')
        
        if [ -z "$deployment_data" ] || [ "$deployment_data" = "null" ]; then
            echo -e "    ${RED}❌ Deployment '${DEPLOY}' not found${NC}"
            continue
        fi
        
        containers=$(echo "$deployment_data" | jq -r '
            .spec.template.spec.containers[] | 
            "    🐳 \(.name): \(.image)"
        ')
        
        if [ -z "$containers" ]; then
            echo -e "    ${YELLOW}⚠️  No containers found${NC}"
        else
            echo "$containers"
        fi
    done
done

echo -e "\n${GREEN}✅ Done checking deployments across all namespaces!${NC}"