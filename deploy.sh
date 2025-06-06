#!/bin/bash

# Auto-Scaling Code-Server Deployment Script
# Part of shlapolosa/idp repository
# This script handles the S3 bucket creation and CloudFormation deployment automatically

set -e  # Exit on any error

# Configuration
STACK_NAME="modern-engineering-workshop"
TEMPLATE_FILE="modern-engineering-workshop.yaml"
REGION="us-east-1"
DRY_RUN=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if AWS CLI is installed and configured
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        echo "Visit: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        exit 1
    fi

    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI is not configured. Please run 'aws configure' first."
        exit 1
    fi

    print_success "AWS CLI is properly configured"
}

# Function to check if template file exists
check_template() {
    if [ ! -f "$TEMPLATE_FILE" ]; then
        print_error "Template file '$TEMPLATE_FILE' not found in current directory."
        echo "Please ensure the CloudFormation template is in the same directory as this script."
        exit 1
    fi
    print_success "Found CloudFormation template: $TEMPLATE_FILE"
}

# Function to validate CloudFormation template
validate_template() {
    print_status "Validating CloudFormation template..."
    
    # Get template size
    local template_size=$(wc -c < "$TEMPLATE_FILE")
    print_status "Template size: $template_size bytes"
    
    # Check if template is too large for direct validation (51,200 bytes limit)
    if [ "$template_size" -gt 51200 ]; then
        print_status "Template size exceeds 51KB, will validate via S3 during deployment"
        return 0
    fi
    
    # Validate template syntax
    local validation_output
    if validation_output=$(aws cloudformation validate-template \
        --template-body "file://$TEMPLATE_FILE" \
        --region "$REGION" 2>&1); then
        print_success "Template validation passed"
        
        # Extract and display template capabilities
        local capabilities=$(echo "$validation_output" | jq -r '.Capabilities[]?' 2>/dev/null | tr '\n' ' ')
        if [[ -n "$capabilities" ]]; then
            print_status "Template requires capabilities: $capabilities"
        fi
        
        # Extract and display template parameters
        local param_count=$(echo "$validation_output" | jq '.Parameters | length' 2>/dev/null)
        if [[ "$param_count" =~ ^[0-9]+$ ]] && [ "$param_count" -gt 0 ]; then
            print_status "Template has $param_count parameters"
        fi
        
        return 0
    else
        print_error "Template validation failed:"
        echo "$validation_output"
        return 1
    fi
}

# Function to validate template parameters
validate_parameters() {
    print_status "Validating template parameters..."
    
    # Check if AnthropicApiKey parameter is properly defined
    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
        if ! grep -q "AnthropicApiKey:" "$TEMPLATE_FILE"; then
            print_error "ANTHROPIC_API_KEY provided but AnthropicApiKey parameter not found in template"
            return 1
        fi
        
        # Validate API key format (basic check)
        if [[ ${#ANTHROPIC_API_KEY} -lt 10 ]]; then
            print_warning "ANTHROPIC_API_KEY seems unusually short, please verify"
        fi
        
        print_success "AnthropicApiKey parameter validation passed"
    fi
    
    return 0
}

# Function to validate input parameters
validate_inputs() {
    print_status "Validating input parameters..."
    
    # Validate stack name format
    if [[ ! "$STACK_NAME" =~ ^[a-zA-Z][-a-zA-Z0-9]*$ ]]; then
        print_error "Invalid stack name: $STACK_NAME"
        echo "Stack name must:"
        echo "  • Start with a letter"
        echo "  • Contain only alphanumeric characters and hyphens"
        echo "  • Be 1-255 characters long"
        return 1
    fi
    
    # Validate stack name length
    if [[ ${#STACK_NAME} -gt 255 ]]; then
        print_error "Stack name too long: ${#STACK_NAME} characters (max 255)"
        return 1
    fi
    
    # Validate AWS region format
    if [[ ! "$REGION" =~ ^[a-z0-9-]+$ ]]; then
        print_error "Invalid AWS region format: $REGION"
        echo "Region must contain only lowercase letters, numbers, and hyphens"
        return 1
    fi
    
    # Validate region length (AWS regions are typically 9-16 characters)
    if [[ ${#REGION} -lt 9 || ${#REGION} -gt 16 ]]; then
        print_warning "Region length unusual: ${#REGION} characters. Please verify: $REGION"
    fi
    
    print_success "Input parameter validation passed"
    return 0
}

# Function to create S3 bucket for CloudFormation
create_s3_bucket() {
    # Generate unique bucket name
    BUCKET_SUFFIX=$(uuidgen | tr -d - | tr '[:upper:]' '[:lower:]' | cut -c1-8)
    BUCKET_NAME="cf-templates-${BUCKET_SUFFIX}-${REGION}"
    
    print_status "Creating S3 bucket: $BUCKET_NAME" >&2
    
    # Check if bucket already exists
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        print_warning "Bucket $BUCKET_NAME already exists, using it" >&2
    else
        # Create bucket
        if [ "$REGION" = "us-east-1" ]; then
            # us-east-1 doesn't need LocationConstraint
            aws s3api create-bucket \
                --bucket "$BUCKET_NAME" \
                --region "$REGION" > /dev/null
        else
            aws s3api create-bucket \
                --bucket "$BUCKET_NAME" \
                --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
        fi
        
        # Enable versioning for safety
        aws s3api put-bucket-versioning \
            --bucket "$BUCKET_NAME" \
            --versioning-configuration Status=Enabled > /dev/null
            
        print_success "Created S3 bucket: $BUCKET_NAME" >&2
    fi
    
    echo "$BUCKET_NAME"
}

# Function to check if stack exists
stack_exists() {
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null
}

# Function to validate stack status
validate_stack_status() {
    if ! stack_exists; then
        print_status "Stack does not exist, will create new stack"
        return 0
    fi
    
    print_status "Checking existing stack status..."
    
    local stack_status
    stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null)
    
    if [[ -z "$stack_status" ]]; then
        print_error "Could not determine stack status"
        return 1
    fi
    
    print_status "Current stack status: $stack_status"
    
    case $stack_status in
        CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE)
            print_success "Stack is in a valid state for updates"
            return 0
            ;;
        CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|DELETE_IN_PROGRESS)
            print_error "Stack operation in progress: $stack_status"
            print_status "Please wait for current operation to complete before retrying"
            return 1
            ;;
        CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|UPDATE_ROLLBACK_FAILED)
            print_error "Stack is in failed state: $stack_status"
            print_status "You may need to delete the stack first:"
            print_status "  aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION"
            return 1
            ;;
        DELETE_COMPLETE)
            print_status "Stack was previously deleted, will create new stack"
            return 0
            ;;
        *)
            print_warning "Unknown stack status: $stack_status"
            print_status "Proceeding with caution..."
            return 0
            ;;
    esac
}

# Function to wait for stack operation to complete
wait_for_stack() {
    local operation=$1
    print_status "Waiting for stack $operation to complete..."
    
    if [ "$operation" = "create" ]; then
        aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION"
    else
        aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$REGION"
    fi
}

# Function to get stack outputs
get_stack_outputs() {
    print_status "Retrieving stack outputs..."
    
    VSCODE_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`VSCodeServerURL`].OutputValue' \
        --output text 2>/dev/null || echo "Not available yet")
    
    VSCODE_PASSWORD=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`VSCodeServerPassword`].OutputValue' \
        --output text 2>/dev/null || echo "Not available yet")
    
    echo
    echo "=================================================="
    echo "🚀 DEPLOYMENT COMPLETE!"
    echo "=================================================="
    echo
    echo "VSCode Server URL: $VSCODE_URL"
    echo "Password: $VSCODE_PASSWORD"
    echo
    echo "📝 Important Notes:"
    echo "• The environment starts with 0 instances (no cost)"
    echo "• First access will take 3-5 minutes to start"
    echo "• Instance auto-shuts down after 5 minutes of inactivity"
    echo "• Auto-scales instance types based on CPU usage"
    echo
    echo "🛠️ Management Commands:"
    echo "• Start manually: aws autoscaling set-desired-capacity --auto-scaling-group-name $STACK_NAME-vscode-asg --desired-capacity 1"
    echo "• Stop manually: aws autoscaling set-desired-capacity --auto-scaling-group-name $STACK_NAME-vscode-asg --desired-capacity 0"
    echo "• Delete stack: aws cloudformation delete-stack --stack-name $STACK_NAME"
    echo
}

# Function to deploy CloudFormation stack
deploy_stack() {
    local bucket_name=$1
    
    # Prepare parameter overrides securely
    local parameter_overrides="AtAnAWSEvent=false"
    
    # Add Anthropic API key if present in environment
    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
        print_status "Found ANTHROPIC_API_KEY environment variable, including in deployment"
        parameter_overrides="AtAnAWSEvent=false AnthropicApiKey=$ANTHROPIC_API_KEY"
    else
        print_warning "ANTHROPIC_API_KEY not found in environment. Claude Code will not be configured."
        print_status "To enable Claude Code, set ANTHROPIC_API_KEY environment variable and redeploy."
    fi
    
    # Deploy stack with enhanced error handling
    local deployment_output
    local operation_type
    
    if stack_exists; then
        operation_type="update"
        print_status "Stack exists, updating..."
    else
        operation_type="create"
        print_status "Creating new stack..."
    fi
    
    if deployment_output=$(aws cloudformation deploy \
        --stack-name "$STACK_NAME" \
        --template-file "$TEMPLATE_FILE" \
        --capabilities CAPABILITY_NAMED_IAM \
        --s3-bucket "$bucket_name" \
        --region "$REGION" \
        --parameter-overrides "$parameter_overrides" 2>&1); then
        
        wait_for_stack "$operation_type"
        print_success "Stack ${operation_type}d successfully!"
    else
        print_error "CloudFormation deployment failed:"
        echo "$deployment_output"
        
        # Show recent stack events for troubleshooting
        print_status "Recent stack events:"
        aws cloudformation describe-stack-events \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'StackEvents[0:5].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]' \
            --output table 2>/dev/null || echo "Could not retrieve stack events"
        
        return 1
    fi
    
}

# Function to handle Lambda@Edge deletion
cleanup_lambda_edge() {
    print_status "Checking for Lambda@Edge functions..."
    
    # Get Lambda@Edge functions from the stack
    local lambda_edge_functions
    lambda_edge_functions=$(aws cloudformation describe-stack-resources \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'StackResources[?ResourceType==`AWS::Lambda::Function`].PhysicalResourceId' \
        --output text 2>/dev/null)
    
    if [[ -n "$lambda_edge_functions" ]]; then
        for function_arn in $lambda_edge_functions; do
            # Check if function is Lambda@Edge (has replicas)
            local replicated_regions
            replicated_regions=$(aws lambda get-function \
                --function-name "$function_arn" \
                --region "$REGION" \
                --query 'Configuration.MasterArn' \
                --output text 2>/dev/null)
            
            if [[ "$replicated_regions" != "None" && "$replicated_regions" != "null" ]]; then
                print_warning "Lambda@Edge function detected: $function_arn"
                print_status "Lambda@Edge functions require manual cleanup:"
                echo "1. Remove CloudFront associations"
                echo "2. Wait for edge replicas to be removed (may take hours)"
                echo "3. Delete the function manually"
                echo
                print_status "To delete manually later:"
                echo "aws lambda delete-function --function-name $function_arn --region $REGION"
            fi
        done
    fi
}

# Function to cleanup on script exit
cleanup() {
    if [ $? -ne 0 ]; then
        print_error "Deployment failed!"
        echo
        echo "🔍 Troubleshooting:"
        echo "• Check CloudFormation console for detailed error messages"
        echo "• Ensure you have sufficient IAM permissions"
        echo "• Verify your AWS CLI region is set correctly"
        echo
        echo "📞 Support:"
        echo "• View logs: aws cloudformation describe-stack-events --stack-name $STACK_NAME"
        echo "• Delete failed stack: aws cloudformation delete-stack --stack-name $STACK_NAME"
        echo
        cleanup_lambda_edge
    fi
}

# Main execution
main() {
    echo "🚀 Auto-Scaling Code-Server Deployment"
    echo "======================================"
    echo
    
    # Setup error handling
    trap cleanup EXIT
    
    # Pre-flight checks
    print_status "Running pre-flight checks..."
    validate_inputs || exit 1
    check_aws_cli
    check_template
    
    # Validate template and parameters
    print_status "Running validation checks..."
    validate_template || exit 1
    validate_parameters || exit 1
    validate_stack_status || exit 1
    
    # Check if this is a dry run
    if [[ "$DRY_RUN" == "true" ]]; then
        print_success "Dry run completed successfully!"
        echo "All validation checks passed. The stack is ready for deployment."
        echo "To deploy, run: $0 (without --dry-run)"
        exit 0
    fi
    
    # Create S3 bucket
    BUCKET_NAME=$(create_s3_bucket)
    
    # Deploy stack
    print_status "Deploying CloudFormation stack..."
    deploy_stack "$BUCKET_NAME" || exit 1
    
    # Show results
    get_stack_outputs
    
    # Remove error trap on successful completion
    trap - EXIT
}

# Show usage if help requested
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Auto-Scaling Code-Server Deployment Script"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --stack-name   Override stack name (default: modern-engineering-workshop)"
    echo "  --region       Override AWS region (default: us-west-2)"
    echo "  --dry-run      Validate template and parameters without deploying"
    echo
    echo "Examples:"
    echo "  $0                                    # Deploy with defaults"
    echo "  $0 --stack-name my-dev-env           # Custom stack name"
    echo "  $0 --region us-east-1                # Different region"
    echo "  $0 --dry-run                         # Validate without deploying"
    echo
    echo "Prerequisites:"
    echo "  • AWS CLI installed and configured"
    echo "  • IAM permissions for CloudFormation, EC2, IAM, S3, Lambda, CloudFront"
    echo "  • modern-engineering-workshop.yaml in current directory"
    echo "  • Repository: https://github.com/shlapolosa/idp"
    echo
    echo "Environment Variables:"
    echo "  • ANTHROPIC_API_KEY - Optional: Enable Claude Code in VSCode"
    echo
    exit 0
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main