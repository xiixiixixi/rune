#!/bin/bash
# 模块依赖规则检查（M2 §4.4 单向依赖红线）
# 用途：检查 Sources/ 各目录的 import 是否符合分层依赖规则。
# 规则：App → 业务模块(Editor/Capture/Preview/Recording/OCR/Views) → CaptureKit/Services → Models
# 红线：Editor 不 import CaptureKit 细节（通过模型通信）；Models 不依赖任何业务模块。
# 运行：bash Scripts/check_dependencies.sh

set -e
cd "$(dirname "$0")/.."

PASS=0
FAIL=0

check() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "✅ $desc"
        PASS=$((PASS+1))
    else
        echo "❌ $desc"
        FAIL=$((FAIL+1))
    fi
}

echo "========== M2 §4.4 模块依赖规则检查 =========="
echo ""

# 规则 1：Editor 不 import CaptureKit（核心红线）
cnt=$(grep -rl "import CaptureKit\|import CaptureKitSCK" Sources/Editor/ 2>/dev/null | wc -l | tr -d ' ')
check "Editor 不 import CaptureKit 细节（§4.4 红线）" "$cnt"

# 规则 2：Models 无业务模块依赖（纯底层）
cnt=$(grep -rh "^import " Sources/Models/ 2>/dev/null | grep -vE "Foundation|AppKit|SwiftUI|CoreGraphics" | wc -l | tr -d ' ')
check "Models 无业务模块依赖（纯底层）" "$cnt"

# 规则 3：业务模块不互相 import（Editor 不 import Preview/Recording/Capture 等）
# 注意：Swift 同 target 内不需要 import 同 target 的目录，所以这条主要查跨 target
cnt=$(grep -rh "^import " Sources/Editor/ 2>/dev/null | grep -vE "Foundation|AppKit|SwiftUI|CoreGraphics|Carbon|Vision|CoreImage|UniformTypeIdentifiers" | wc -l | tr -d ' ')
check "Editor 无跨 target 业务依赖" "$cnt"

# 规则 4：CaptureKit（纯逻辑包）不依赖 UI/业务
cnt=$(grep -rh "^import " CaptureKit/Sources/CaptureKit/ 2>/dev/null | grep -vE "Foundation|CoreGraphics" | wc -l | tr -d ' ')
check "CaptureKit 纯逻辑包无 UI/业务依赖" "$cnt"

echo ""
echo "========== 结果: $PASS 通过, $FAIL 失败 =========="
[ "$FAIL" = "0" ] && echo "✅ 所有依赖规则检查通过" || echo "❌ 存在违反规则的依赖"
exit $FAIL
