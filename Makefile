# Vista Gateway Build and Deployment Makefile
#
# Usage:
#   make image          - Build full Yocto image using kas
#   make webui          - Build the React web UI using Docker
#   make deploy-webui   - Deploy web UI to target device (set TARGET_IP)
#   make all            - Build web UI and full image
#
# Environment variables:
#   TARGET_IP          - IP address or hostname of target device (default: vista-00018.local)
#   KAS_FILE           - KAS configuration file (default: kas/seeed-recomputer-r110x-mender.yml)
#   BUILD_DIR          - Build directory (default: build)

TARGET_IP ?= vista-00018.local
KAS_FILE ?= kas/seeed-recomputer-r110x-mender.yml
BUILD_DIR ?= build
WEBUI_DIR = layers/meta-vista/recipes-extended/vista-web-ui/files
WEBUI_DIST = $(WEBUI_DIR)/dist

.PHONY: help image webui deploy-webui clean-webui package-webui all check-env check-webui check-image

help:
	@echo "Vista Gateway Build and Deployment"
	@echo ""
	@echo "Targets:"
	@echo "  make image          - Build full Yocto image using kas"
	@echo "  make webui          - Build the React web UI using Docker"
	@echo "  make package-webui - Build web UI IPK package (requires kas)"
	@echo "  make deploy-webui   - Build package and deploy to target device"
	@echo "  make clean-webui   - Clean web UI build artifacts"
	@echo "  make check-webui   - Check if web UI is built"
	@echo "  make check-image   - Check if image is built"
	@echo "  make all            - Build web UI and full image"
	@echo ""
	@echo "Environment variables:"
	@echo "  TARGET_IP          - Target device IP/hostname (default: vista-00018.local)"
	@echo "  KAS_FILE           - KAS config file (default: kas/seeed-recomputer-r110x-mender.yml)"
	@echo "  BUILD_DIR          - Build directory (default: build)"
	@echo ""
	@echo "Examples:"
	@echo "  make image"
	@echo "  make webui"
	@echo "  make deploy-webui TARGET_IP=192.168.1.100"
	@echo "  make all TARGET_IP=vista-00018.local"

# Build the React web UI using Docker
webui:
	@echo "=========================================="
	@echo "Building Vista Web UI"
	@echo "=========================================="
	@if [ ! -f "$(WEBUI_DIR)/build.sh" ]; then \
		echo "Error: Web UI build script not found at $(WEBUI_DIR)/build.sh"; \
		exit 1; \
	fi
	@cd $(WEBUI_DIR) && ./build.sh
	@if [ ! -d "$(WEBUI_DIST)" ] || [ ! -f "$(WEBUI_DIST)/index.html" ]; then \
		echo "Error: Web UI build failed - dist directory or index.html not found"; \
		exit 1; \
	fi
	@echo "Web UI built successfully: $(WEBUI_DIST)"

# Build the full Yocto image using kas
image: webui
	@echo "=========================================="
	@echo "Building Vista Image with kas"
	@echo "=========================================="
	@if [ ! -f "$(KAS_FILE)" ]; then \
		echo "Error: KAS file not found: $(KAS_FILE)"; \
		exit 1; \
	fi
	@if [ ! -f "kas-build.sh" ]; then \
		echo "Error: kas-build.sh not found"; \
		exit 1; \
	fi
	@echo "Using KAS file: $(KAS_FILE)"
	@echo "Build directory: $(BUILD_DIR)"
	@echo ""
	@echo "Note: This will use kas-build.sh which validates MENDER_TOKEN and SCRIPT_SIGNING_KEY"
	@echo ""
	@./kas-build.sh build $(KAS_FILE)
	@echo ""
	@echo "Image build complete. Artifacts in: $(BUILD_DIR)/tmp/deploy/images/"

# Build the web UI package (IPK) using bitbake
package-webui: webui
	@echo "=========================================="
	@echo "Building Vista Web UI Package"
	@echo "=========================================="
	@if [ ! -d "$(WEBUI_DIST)" ]; then \
		echo "Error: Web UI not built. Run 'make webui' first."; \
		exit 1; \
	fi
	@echo "Building IPK package with bitbake..."
	@if command -v kas >/dev/null 2>&1; then \
		kas shell $(KAS_FILE) -c "bitbake vista-web-ui"; \
	else \
		echo "Error: kas not found. Please install kas or use 'make image' instead"; \
		exit 1; \
	fi
	@echo "Package build complete. IPK location:"
	@find $(BUILD_DIR)/tmp/deploy/ipk -name "vista-web-ui_*.ipk" 2>/dev/null | head -1 || \
		echo "  (IPK not found - check build output)"

# Deploy web UI to target device
deploy-webui: check-env package-webui
	@echo "=========================================="
	@echo "Deploying Vista Web UI to $(TARGET_IP)"
	@echo "=========================================="
	@IPK_FILE=$$(find $(BUILD_DIR)/tmp/deploy/ipk -name "vista-web-ui_*.ipk" 2>/dev/null | head -1); \
	if [ -z "$$IPK_FILE" ]; then \
		echo "Error: IPK package not found. Building package..."; \
		$(MAKE) package-webui; \
		IPK_FILE=$$(find $(BUILD_DIR)/tmp/deploy/ipk -name "vista-web-ui_*.ipk" 2>/dev/null | head -1); \
		if [ -z "$$IPK_FILE" ]; then \
			echo "Error: Failed to build IPK package"; \
			exit 1; \
		fi; \
	fi
	@IPK_FILE=$$(find $(BUILD_DIR)/tmp/deploy/ipk -name "vista-web-ui_*.ipk" 2>/dev/null | head -1); \
	echo "Found IPK: $$IPK_FILE"; \
	echo "Copying to target device..."; \
	scp "$$IPK_FILE" root@$(TARGET_IP):/tmp/vista-web-ui.ipk || { \
		echo "Error: Failed to copy IPK to device. Check:"; \
		echo "  1. Device is reachable: ping $(TARGET_IP)"; \
		echo "  2. SSH access is configured"; \
		echo "  3. TARGET_IP is correct (current: $(TARGET_IP))"; \
		exit 1; \
	}; \
	echo "Installing package on device..."; \
	ssh root@$(TARGET_IP) "opkg install --force-reinstall /tmp/vista-web-ui.ipk && systemctl restart lighttpd" || { \
		echo "Error: Failed to install package on device"; \
		exit 1; \
	}; \
	echo "Cleaning up temporary file..."; \
	ssh root@$(TARGET_IP) "rm -f /tmp/vista-web-ui.ipk" || true; \
	echo ""; \
	echo "=========================================="; \
	echo "Deployment complete!"; \
	echo "=========================================="; \
	echo "Web UI should now be available at:"; \
	echo "  https://$(TARGET_IP)"; \
	echo "  https://$(TARGET_IP)/login"

# Clean web UI build artifacts
clean-webui:
	@echo "Cleaning web UI build artifacts..."
	@if [ -d "$(WEBUI_DIST)" ]; then \
		docker run --rm -v "$(PWD)/$(WEBUI_DIR):/output" alpine:latest sh -c "rm -rf /output/dist" 2>/dev/null || \
		rm -rf "$(WEBUI_DIST)"; \
		echo "Cleaned $(WEBUI_DIST)"; \
	else \
		echo "No web UI build artifacts to clean"; \
	fi

# Build web UI and full image
all: image

# Check that TARGET_IP is set (for deploy target)
check-env:
	@if [ -z "$(TARGET_IP)" ]; then \
		echo "Error: TARGET_IP not set. Set it via:"; \
		echo "  export TARGET_IP=<device-ip>"; \
		echo "  or"; \
		echo "  make deploy-webui TARGET_IP=<device-ip>"; \
		exit 1; \
	fi

# Quick check targets
check-webui:
	@if [ -d "$(WEBUI_DIST)" ] && [ -f "$(WEBUI_DIST)/index.html" ]; then \
		echo "✓ Web UI is built"; \
		ls -lh "$(WEBUI_DIST)/index.html" "$(WEBUI_DIST)/assets/" 2>/dev/null | head -5; \
	else \
		echo "✗ Web UI is not built. Run 'make webui'"; \
		exit 1; \
	fi

check-image:
	@if [ -d "$(BUILD_DIR)/tmp/deploy/images" ]; then \
		echo "✓ Image build directory exists"; \
		ls -1 "$(BUILD_DIR)/tmp/deploy/images/" 2>/dev/null | head -5; \
	else \
		echo "✗ Image not built. Run 'make image'"; \
		exit 1; \
	fi
