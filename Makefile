.PHONY: help init validate format plan apply destroy rebuild state output console clean

TERRAFORM_DIR := terraform
TF := terraform

help:
	@echo "Terraform Management for Pi-hole OCI Infrastructure"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  init       Initialize terraform (download providers, setup state)"
	@echo "  validate   Validate terraform configuration"
	@echo "  format     Format terraform files"
	@echo "  plan       Plan infrastructure changes"
	@echo "  apply      Apply infrastructure changes"
	@echo "  destroy    Destroy all infrastructure"
	@echo "  rebuild    Destroy and rebuild from scratch (interactive confirmation)"
	@echo "  state      Show current terraform state"
	@echo "  output     Show terraform outputs"
	@echo "  console    Open terraform console for debugging"
	@echo "  clean      Remove terraform state files"
	@echo "  help       Display this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make init"
	@echo "  make plan"
	@echo "  make apply"
	@echo "  make rebuild"
	@echo "  make destroy"

check-prerequisites:
	@command -v $(TF) >/dev/null 2>&1 || { echo "ERROR: Terraform is not installed or not in PATH"; exit 1; }
	@echo "Terraform found: $$($(TF) version | head -1)"
	@test -d $(TERRAFORM_DIR) || { echo "ERROR: Terraform directory not found: $(TERRAFORM_DIR)"; exit 1; }
	@echo "Terraform directory found: $(TERRAFORM_DIR)"
	@test -f $(TERRAFORM_DIR)/terraform.tfvars || echo "WARNING: terraform.tfvars not found. Please create it from terraform.tfvars.example"
	@test -f $(TERRAFORM_DIR)/terraform.tfvars && echo "terraform.tfvars found" || true

init: check-prerequisites
	@echo "Initializing Terraform..."
	@cd $(TERRAFORM_DIR) && $(TF) init
	@echo "Terraform initialization successful"

validate: check-prerequisites
	@echo "Validating Terraform configuration..."
	@cd $(TERRAFORM_DIR) && $(TF) validate
	@echo "Terraform validation successful"

format: check-prerequisites
	@echo "Formatting Terraform files..."
	@cd $(TERRAFORM_DIR) && $(TF) fmt -recursive
	@echo "Terraform formatting complete"

plan: check-prerequisites
	@echo "Planning infrastructure changes..."
	@cd $(TERRAFORM_DIR) && $(TF) plan -out=tfplan
	@echo "Terraform plan successful"
	@echo "Plan saved to tfplan. Use 'make apply' to apply changes."

apply: check-prerequisites
	@echo "Applying infrastructure changes..."
	@cd $(TERRAFORM_DIR) && \
		if [ -f tfplan ]; then \
			echo "Applying saved plan..."; \
			$(TF) apply tfplan; \
		else \
			echo "No saved plan found. Creating new plan and applying..."; \
			$(TF) apply; \
		fi
	@echo "Terraform apply successful"

destroy: check-prerequisites
	@echo "Preparing to destroy infrastructure..."
	@echo "WARNING: This will destroy all infrastructure!"
	@read -p "Are you sure you want to DESTROY all infrastructure? Type 'yes' to confirm: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		cd $(TERRAFORM_DIR) && $(TF) destroy; \
		echo "Terraform destroy successful"; \
	else \
		echo "Destroy cancelled"; \
	fi

clean: check-prerequisites
	@echo "Removing terraform state files..."
	@cd $(TERRAFORM_DIR) && \
		rm -f terraform.tfstate && \
		echo "Removed terraform.tfstate"; \
		rm -f terraform.tfstate.backup && \
		echo "Removed terraform.tfstate.backup"; \
		rm -f .terraform.lock.hcl && \
		echo "Removed .terraform.lock.hcl"; \
		rm -f tfplan && \
		echo "Removed tfplan"

state: check-prerequisites
	@echo "Current Terraform state:"
	@cd $(TERRAFORM_DIR) && $(TF) state list

output: check-prerequisites
	@echo "Terraform outputs:"
	@cd $(TERRAFORM_DIR) && $(TF) output

console: check-prerequisites
	@echo "Opening Terraform console..."
	@echo "Type 'exit' to quit the console"
	@cd $(TERRAFORM_DIR) && $(TF) console

rebuild: check-prerequisites
	@echo "=========================================================="
	@echo "REBUILD FROM SCRATCH - This will destroy all resources"
	@echo "=========================================================="
	@read -p "Are you sure? Type 'yes' to proceed with complete rebuild: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		echo "Step 1: Destroying existing infrastructure..."; \
		cd $(TERRAFORM_DIR) && $(TF) destroy -auto-approve || exit 1; \
		echo "Destroy complete"; \
		echo "Step 2: Removing state files..."; \
		rm -f terraform.tfstate && echo "Removed terraform.tfstate"; \
		rm -f terraform.tfstate.backup && echo "Removed terraform.tfstate.backup"; \
		rm -f .terraform.lock.hcl && echo "Removed .terraform.lock.hcl"; \
		echo "Step 3: Reinitializing Terraform..."; \
		$(TF) init || exit 1; \
		echo "Step 4: Creating infrastructure plan..."; \
		$(TF) plan -out=tfplan || exit 1; \
		echo "Step 5: Applying infrastructure..."; \
		$(TF) apply tfplan || exit 1; \
		echo "==========================================================="; \
		echo "REBUILD COMPLETE!"; \
		echo "==========================================================="; \
		echo "New infrastructure outputs:"; \
		$(TF) output; \
	else \
		echo "Rebuild cancelled"; \
	fi
