#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'


show_usage() {
    echo -e "${CYAN}Usage: $0 [OPTIONS] [NAMESPACE...]${NC}"
    echo -e "${YELLOW}Options:${NC}"
    echo "  -f, --file FILE     Read namespaces from file (one per line)"
    echo "  -a, --auto          Auto-detect stuck namespaces (recommended)"
    echo "  -d, --dry-run       Show what would be done without executing"
    echo "  -h, --help          Show this help message"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  $0 -a                                 # Auto-detect stuck namespaces"
    echo "  $0 namespace1 namespace2              # Specify namespaces manually"
    echo "  $0 -f namespaces.txt                  # Read from file"
    echo "  $0 -a -d                              # Auto-detect with dry run"
}

auto_detect_stuck_namespaces() {
    echo -e "${BLUE}🔍 Auto-detecting stuck namespaces...${NC}"
    
    local stuck_namespaces
    if ! stuck_namespaces=$(kubectl --kubeconfig /home/appadmins/config get namespaces --no-headers 2>/dev/null | \
        awk '$2 == "Terminating" {print $1}'); then
        echo -e "${RED}❌ Failed to get namespaces${NC}"
        return 1
    fi

    if [ -z "$stuck_namespaces" ]; then
        echo -e "${GREEN}✅ No stuck namespaces found!${NC}"
        return 1
    fi

    echo -e "${YELLOW}Found stuck namespaces:${NC}"
    echo "$stuck_namespaces" | while read -r ns; do
        echo -e "  ${RED}📦 $ns${NC}"
    done
    
    echo "$stuck_namespaces"
    return 0
}

# Function to validate namespace exists and is stuck
validate_namespace() {
    local ns="$1"
    local status
    
    if ! status=$(kubectl --kubeconfig /home/appadmins/config get namespace "$ns" --no-headers 2>/dev/null | awk '{print $2}'); then
        echo -e "  ${YELLOW}⚠️  Namespace '$ns' not found, skipping${NC}"
        return 1
    fi
    
    if [ "$status" != "Terminating" ]; then
        echo -e "  ${YELLOW}⚠️  Namespace '$ns' is not stuck (status: $status), skipping${NC}"
        return 1
    fi
    
    return 0
}

patch_namespace_finalizers() {
    local ns="$1"
    local dry_run="$2"
    
    echo -e "  ${BLUE}🔧 Processing namespace: $ns${NC}"
    
    if ! validate_namespace "$ns"; then
        return 1
    fi
    
    if [ "$dry_run" = "true" ]; then
        echo -e "  ${CYAN}[DRY RUN] Would patch finalizers for: $ns${NC}"
        return 0
    fi
    
    if kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - <<EOF 2>/dev/null
{
  "apiVersion": "v1",
  "kind": "Namespace",
  "metadata": {
    "name": "$ns"
  },
  "spec": {
    "finalizers": []
  }
}
EOF
    then
        echo -e "  ${GREEN}✅ Successfully patched: $ns${NC}"
        return 0
    else
        echo -e "  ${RED}❌ Failed to patch: $ns${NC}"
        return 1
    fi
}

read_namespaces_from_file() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        echo -e "${RED}❌ File not found: $file${NC}"
        exit 1
    fi
    
    # Read and filter out empty lines and comments
    grep -v '^#' "$file" | grep -v '^[[:space:]]*$'
}

namespaces=()
use_file=false
auto_detect=false
dry_run=false
file_path=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            use_file=true
            file_path="$2"
            shift 2
            ;;
        -a|--auto)
            auto_detect=true
            shift
            ;;
        -d|--dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
        *)
            namespaces+=("$1")
            shift
            ;;
    esac
done

main() {
    echo -e "${CYAN}🚀 Stuck Namespace Cleaner${NC}"
    echo "======================================="
    
    check_prerequisites
    
    local target_namespaces=()
    
    if [ "$auto_detect" = "true" ]; then
        if auto_detected=$(auto_detect_stuck_namespaces); then
            mapfile -t target_namespaces <<< "$auto_detected"
        else
            exit 0
        fi
    elif [ "$use_file" = "true" ]; then
        echo -e "${BLUE}📁 Reading namespaces from file: $file_path${NC}"
        mapfile -t target_namespaces <<< "$(read_namespaces_from_file "$file_path")"
    elif [ ${#namespaces[@]} -gt 0 ]; then
        target_namespaces=("${namespaces[@]}")
    else
        echo -e "${RED}❌ No namespaces specified${NC}"
        echo -e "${YELLOW}💡 Use one of the following options:${NC}"
        echo -e "   • ${CYAN}$0 -a${NC}                    # Auto-detect stuck namespaces"
        echo -e "   • ${CYAN}$0 namespace1 namespace2${NC}  # Specify namespaces manually"
        echo -e "   • ${CYAN}$0 -f namespaces.txt${NC}      # Read from file"
        echo -e "   • ${CYAN}$0 -h${NC}                     # Show full help"
        exit 1
    fi
    
    if [ "$dry_run" = "true" ]; then
        echo -e "\n${CYAN}🔍 DRY RUN MODE - No actual changes will be made${NC}"
    fi
    
    echo -e "\n${YELLOW}📦 Target namespaces (${#target_namespaces[@]} total):${NC}"
    for ns in "${target_namespaces[@]}"; do
        echo -e "  • $ns"
    done
    
    if [ "$dry_run" = "false" ] && [ "$auto_detect" = "false" ]; then
        echo -e "\n${YELLOW}⚠️  This will force-delete stuck namespaces by removing finalizers${NC}"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}❌ Aborted by user${NC}"
            exit 0
        fi
    fi
    
    echo -e "\n${BLUE}🔧 Processing namespaces...${NC}"
    local success_count=0
    local failed_count=0
    local skipped_count=0
    
    for ns in "${target_namespaces[@]}"; do
        if patch_namespace_finalizers "$ns" "$dry_run"; then
            ((success_count++))
        else
            if validate_namespace "$ns" &>/dev/null; then
                ((failed_count++))
            else
                ((skipped_count++))
            fi
        fi
    done
    
    echo -e "\n${CYAN}📊 Summary:${NC}"
    echo -e "  ${GREEN}✅ Successful: $success_count${NC}"
    if [ $failed_count -gt 0 ]; then
        echo -e "  ${RED}❌ Failed: $failed_count${NC}"
    fi
    if [ $skipped_count -gt 0 ]; then
        echo -e "  ${YELLOW}⏭️  Skipped: $skipped_count${NC}"
    fi
    
    if [ "$dry_run" = "false" ] && [ $success_count -gt 0 ]; then
        echo -e "\n${GREEN}✅ Execution completed!${NC}"
        echo -e "${YELLOW}💡 Check results with: ${CYAN}kubectl get namespaces${NC}"
        
        echo -e "\n${BLUE}🔍 Checking for remaining stuck namespaces...${NC}"
        if remaining=$(kubectl get namespaces --no-headers 2>/dev/null | awk '$2 == "Terminating" {print $1}'); then
            if [ -n "$remaining" ]; then
                echo -e "${YELLOW}Still stuck:${NC}"
                echo "$remaining" | while read -r ns; do
                    echo -e "  ${RED}📦 $ns${NC}"
                done
            else
                echo -e "${GREEN}✅ No stuck namespaces remaining!${NC}"
            fi
        fi
    fi
}

main "$@"