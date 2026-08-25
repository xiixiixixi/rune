# Rune Makefile
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

SCHEME       = Rune
PROJECT      = Rune.xcodeproj
PRODUCT_NAME = Rune
CONFIG_DEBUG = Debug
CONFIG_REL   = Release
DERIVED_DIR  = .build
APP_DEBUG    = $(DERIVED_DIR)/Build/Products/$(CONFIG_DEBUG)/$(PRODUCT_NAME).app
APP_RELEASE  = $(DERIVED_DIR)/Build/Products/$(CONFIG_REL)/$(PRODUCT_NAME).app
VERSION     := $(shell python3 -c "import json; print(json.load(open('version.json'))['version'])")
DMG_NAME     = Rune-$(VERSION).dmg
DMG_DIR      = release
# 正式 Apple 证书可通过 LOCAL_SIGN_IDENTITY 覆盖。本地默认使用 ad-hoc 签名，
# 但显式固定 designated requirement，避免每次编译都因 cdhash 变化而丢失屏幕录制权限。
# 稳定签名身份：所有版本共用这张 Apple Development 证书，
# 换包/自动更新后 TCC 授权（屏幕录制等）持续有效，无需重新授权。
LOCAL_SIGN_IDENTITY ?= Apple Development: xiixiixixi@gmail.com (XZTBXM8859)
ifeq ($(strip $(LOCAL_SIGN_IDENTITY)),-)
LOCAL_SIGN_REQUIREMENTS = --requirements '=designated => identifier "com.tc.rune"'
endif

.PHONY: build release run dmg clean lint test-build version ship help sync-version

sync-version: ## 从 version.json 同步版本号进工程（单一版本源头）
	@python3 -c 'import json, re; v = json.load(open("version.json")); y = open("project.yml").read(); y = re.sub("MARKETING_VERSION: \"[^\"]*\"", "MARKETING_VERSION: " + chr(34) + v["version"] + chr(34), y); y = re.sub("CURRENT_PROJECT_VERSION: \"[^\"]*\"", "CURRENT_PROJECT_VERSION: " + chr(34) + str(v["build"]) + chr(34), y); open("project.yml", "w").write(y); print("==> 版本同步: " + v["version"] + " (build " + str(v["build"]) + ")")'
	@xcodegen generate >/dev/null 2>&1

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: sync-version ## 编译调试版并固定签名
	@echo "==> 正在编译 Rune（调试版）…"
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
		codesign --force --options runtime --timestamp=none --identifier com.tc.rune.preview \
		--sign "$(LOCAL_SIGN_IDENTITY)" "$(APP_DEBUG)/Contents/MacOS/__preview.dylib"; \
	fi
	@if [ -f "$(APP_DEBUG)/Contents/MacOS/$(PRODUCT_NAME).debug.dylib" ]; then \
		codesign --force --options runtime --timestamp=none --identifier com.tc.rune.debug \
		--sign "$(LOCAL_SIGN_IDENTITY)" "$(APP_DEBUG)/Contents/MacOS/$(PRODUCT_NAME).debug.dylib"; \
	fi
	@codesign --force --options runtime --timestamp=none --identifier com.tc.rune \
		--entitlements Resources/Rune.entitlements \
		$(LOCAL_SIGN_REQUIREMENTS) \
		--sign "$(LOCAL_SIGN_IDENTITY)" "$(APP_DEBUG)"
	@codesign --verify --deep --strict "$(APP_DEBUG)"
	@echo "==> $(APP_DEBUG)"

release: sync-version ## 编译双架构正式版并完成本地签名
	@echo "==> 正在编译 Rune（双架构正式版）…"
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
	@codesign --force --options runtime --timestamp=none --identifier com.tc.rune \
		--entitlements Resources/Rune.entitlements \
		$(LOCAL_SIGN_REQUIREMENTS) \
		--sign "$(LOCAL_SIGN_IDENTITY)" "$(APP_RELEASE)"
	@codesign --verify --deep --strict "$(APP_RELEASE)"
	@echo "==> $(APP_RELEASE)"

run: build ## 编译并启动调试版
	@echo "==> 正在启动 Rune…"
	@open "$(APP_DEBUG)"

dmg: release ## 创建本地安装包 + 自动更新包
	@echo "==> 正在创建 Rune 安装包…"
	@mkdir -p $(DMG_DIR)/staging
	@cp -R "$(APP_RELEASE)" $(DMG_DIR)/staging/
	@cp LICENSE $(DMG_DIR)/staging/LICENSE
	@ln -sf /Applications $(DMG_DIR)/staging/Applications
	@hdiutil create -volname "Rune" \
		-srcfolder $(DMG_DIR)/staging \
		-ov -format UDZO \
		"$(DMG_DIR)/$(DMG_NAME)" 2>/dev/null
	@rm -rf $(DMG_DIR)/staging
	@echo "==> $(DMG_DIR)/$(DMG_NAME)"
	@echo "==> 正在创建自动更新包（zip）…"
	@ditto -c -k --keepParent "$(APP_RELEASE)" "$(DMG_DIR)/Rune-$(VERSION).zip"
	@cp "$(DMG_DIR)/Rune-$(VERSION).zip" "$(DMG_DIR)/Rune-latest.zip"
	@echo "==> $(DMG_DIR)/Rune-$(VERSION).zip（含固定名副本 Rune-latest.zip 供应用内更新）"

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
