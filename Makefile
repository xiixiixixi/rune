# 轻截 Makefile
# Usage:
#   make build        — Debug build
#   make release      — Release build
#   make run          — Build and launch (debug)
#   make dmg          — Create unsigned DMG for local testing
#   make clean        — Remove build artifacts
#   make lint         — Swift compiler warnings check
#   make test-build   — Full clean + release build to verify everything compiles
#   make version      — Print current version
#   make ship         — Signed release: build, sign, notarize, DMG (both architectures)

SHELL := /bin/bash

SCHEME       = BetterShot
PROJECT      = BetterShot.xcodeproj
PRODUCT_NAME = 轻截
CONFIG_DEBUG = Debug
CONFIG_REL   = Release
DERIVED_DIR  = .build
APP_DEBUG    = $(DERIVED_DIR)/Build/Products/$(CONFIG_DEBUG)/$(PRODUCT_NAME).app
APP_RELEASE  = $(DERIVED_DIR)/Build/Products/$(CONFIG_REL)/$(PRODUCT_NAME).app
VERSION     := $(shell python3 -c "import json; print(json.load(open('version.json'))['version'])")
DMG_NAME     = 轻截-$(VERSION).dmg
DMG_DIR      = release
# 当前 Mac 的固定本地开发证书。每次编译后使用同一张证书重新签名，
# 让系统屏幕录制权限按“应用身份”识别，而不是按每次都会变化的文件指纹识别。
LOCAL_SIGN_IDENTITY ?= D9517CC9A217E88617CE0780866A2C259552A769

.PHONY: build release run dmg clean lint test-build version ship help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## 编译调试版并固定签名
	@echo "==> 正在编译轻截（调试版）…"
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination 'platform=macOS,arch=arm64' \
		-configuration $(CONFIG_DEBUG) \
		-derivedDataPath $(DERIVED_DIR) \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		-quiet \
		build
	@if [ -f "$(APP_DEBUG)/Contents/MacOS/__preview.dylib" ]; then \
		codesign --force --options runtime --timestamp=none --identifier com.tc.qingjie.preview \
		--sign "$(LOCAL_SIGN_IDENTITY)" "$(APP_DEBUG)/Contents/MacOS/__preview.dylib"; \
	fi
	@if [ -f "$(APP_DEBUG)/Contents/MacOS/$(PRODUCT_NAME).debug.dylib" ]; then \
		codesign --force --options runtime --timestamp=none --identifier com.tc.qingjie.debug \
		--sign "$(LOCAL_SIGN_IDENTITY)" "$(APP_DEBUG)/Contents/MacOS/$(PRODUCT_NAME).debug.dylib"; \
	fi
	@codesign --force --options runtime --timestamp=none --identifier com.tc.qingjie \
		--entitlements Resources/BetterShot.entitlements \
		--sign "$(LOCAL_SIGN_IDENTITY)" "$(APP_DEBUG)"
	@codesign --verify --deep --strict "$(APP_DEBUG)"
	@echo "==> $(APP_DEBUG)"

release: ## 编译双架构正式版并固定签名
	@echo "==> 正在编译轻截（双架构正式版）…"
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination 'generic/platform=macOS' \
		-configuration $(CONFIG_REL) \
		-derivedDataPath $(DERIVED_DIR) \
		ARCHS="arm64 x86_64" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO \
		-quiet \
		build
	@codesign --force --options runtime --timestamp=none --identifier com.tc.qingjie \
		--entitlements Resources/BetterShot.entitlements \
		--sign "$(LOCAL_SIGN_IDENTITY)" "$(APP_RELEASE)"
	@codesign --verify --deep --strict "$(APP_RELEASE)"
	@echo "==> $(APP_RELEASE)"

run: build ## 编译并启动调试版
	@echo "==> 正在启动轻截…"
	@open "$(APP_DEBUG)"

dmg: release ## 创建本地安装包
	@echo "==> 正在创建轻截安装包…"
	@mkdir -p $(DMG_DIR)/staging
	@cp -R "$(APP_RELEASE)" $(DMG_DIR)/staging/
	@ln -sf /Applications $(DMG_DIR)/staging/Applications
	@hdiutil create -volname "轻截" \
		-srcfolder $(DMG_DIR)/staging \
		-ov -format UDZO \
		"$(DMG_DIR)/$(DMG_NAME)" 2>/dev/null
	@rm -rf $(DMG_DIR)/staging
	@echo "==> $(DMG_DIR)/$(DMG_NAME)"

clean: ## Remove build artifacts
	@echo "==> Cleaning..."
	@rm -rf $(DERIVED_DIR)
	@rm -rf $(DMG_DIR)/staging
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
	@echo "==> Clean."

lint: ## Check for compiler warnings
	@echo "==> Checking for warnings..."
	@xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG_DEBUG) \
		-derivedDataPath $(DERIVED_DIR) \
		build 2>&1 | grep -E "warning:|error:" || echo "No warnings."

test-build: clean release ## Full clean + release build
	@echo "==> Test build passed."

ship: ## Signed release: build, sign, notarize, DMG (both architectures)
	@bash scripts/release.sh

version: ## Print current version
	@echo "$(VERSION)"
