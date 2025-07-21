#!/bin/bash

NAMESPACE="${1:-galilei}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}🔍 Node Pod Capacity Analysis${NC}"
echo -e "${YELLOW}Namespace context: $NAMESPACE${NC}"
echo "================================================================================"

echo -e "${BLUE}📊 Fetching nodes data...${NC}"
if ! nodes_info=$(kubectl get nodes \
    -o custom-columns=NAME:.metadata.name,MAX_PODS:.status.allocatable.pods \
    --no-headers 2>/dev/null); then
    echo -e "${RED}❌ Failed to get nodes data${NC}"
    exit 1
fi

echo -e "${BLUE}📦 Fetching pods data...${NC}"
if ! pods_per_node=$(kubectl get pods --all-namespaces \
    -o custom-columns=NODE:.spec.nodeName --no-headers 2>/dev/null | \
    sort | uniq -c | awk '{print $2":"$1}'); then
    echo -e "${RED}❌ Failed to get pods data${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Data fetched successfully!${NC}\n"

declare -A pod_counts
while IFS=':' read -r node count; do
    if [ -n "$node" ] && [ "$node" != "<none>" ]; then
        pod_counts["$node"]=$count
    fi
done <<< "$pods_per_node"

printf "${CYAN}%-40s %-10s %-10s %-12s %-10s${NC}\n" "Node Name" "Max Pods" "Used" "Available" "Usage %"
echo "========================================================================================="

total_max=0
total_used=0

while IFS=$'\t' read -r node max_pods; do
    [ -z "$node" ] && continue
    
    used_pods=${pod_counts[$node]:-0}
    
    available_pods=$((max_pods - used_pods))
    
    if [ "$max_pods" -gt 0 ]; then
        usage_percent=$(awk "BEGIN {printf \"%.1f\", ($used_pods/$max_pods)*100}")
    else
        usage_percent="0.0"
    fi
    
    if awk "BEGIN {exit !($usage_percent >= 90)}"; then
        color=$RED
    elif awk "BEGIN {exit !($usage_percent >= 70)}"; then
        color=$YELLOW
    else
        color=$GREEN
    fi
    
    printf "${color}%-40s %-10s %-10s %-12s %-10s${NC}\n" \
        "$node" "$max_pods" "$used_pods" "$available_pods" "${usage_percent}%"
    
    total_max=$((total_max + max_pods))
    total_used=$((total_used + used_pods))
    
done <<< "$(echo "$nodes_info" | tr -s ' ' '\t')"

echo "========================================================================================="

total_available=$((total_max - total_used))
if [ "$total_max" -gt 0 ]; then
    cluster_usage=$(awk "BEGIN {printf \"%.1f\", ($total_used/$total_max)*100}")
else
    cluster_usage="0.0"
fi

echo -e "\n${CYAN}📊 Cluster Summary:${NC}"
echo -e "  ${BLUE}Total Max Pods:${NC}      $total_max"
echo -e "  ${YELLOW}Total Used Pods:${NC}     $total_used"
echo -e "  ${GREEN}Total Available:${NC}     $total_available"
echo -e "  ${CYAN}Cluster Usage:${NC}       ${cluster_usage}%"

high_usage_nodes=$(echo "$nodes_info" | tr -s ' ' '\t' | while IFS=$'\t' read -r node max_pods; do
    [ -z "$node" ] && continue
    used_pods=${pod_counts[$node]:-0}
    if [ "$max_pods" -gt 0 ]; then
        usage_percent=$(awk "BEGIN {printf \"%.1f\", ($used_pods/$max_pods)*100}")
        if awk "BEGIN {exit !($usage_percent >= 90)}"; then
            echo "$node"
        fi
    fi
done | wc -l)

echo -e "  ${RED}High Usage Nodes (≥90%):${NC} $high_usage_nodes"

if awk "BEGIN {exit !($cluster_usage >= 80)}"; then
    echo -e "\n${RED}⚠️  WARNING: Cluster pod usage is high (${cluster_usage}%)${NC}"
    echo -e "   ${YELLOW}Consider scaling up or optimizing pod distribution${NC}"
fi

if [ "$high_usage_nodes" -gt 0 ]; then
    echo -e "\n${RED}⚠️  WARNING: $high_usage_nodes node(s) have critical pod usage (≥90%)${NC}"
    echo -e "   ${YELLOW}These nodes may experience scheduling issues${NC}"
fi

echo -e "\n${GREEN}✅ Analysis complete!${NC}"