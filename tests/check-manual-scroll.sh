#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$TASK_ROOT/build/test-module-cache"
# Same-file extension access avoids changing the production matcher's visibility.
cat "$TASK_ROOT/Textream/Textream/SpeechRecognizer.swift" \
    "$TASK_ROOT/tests/manual-scroll.swift" > "$TASK_ROOT/build/RecognizerManualScrollChecks.swift"
xcrun swiftc -parse-as-library \
    -module-cache-path "$TASK_ROOT/build/test-module-cache" \
    -target "$(uname -m)-apple-macos15.0" \
    "$TASK_ROOT/Textream/Textream/MarqueeTextView.swift" \
    "$TASK_ROOT/Textream/Textream/SpeechTextAlignment.swift" \
    "$TASK_ROOT/Textream/Textream/TextDirection.swift" \
    "$TASK_ROOT/Textream/Textream/VoiceActivityDetector.swift" \
    "$TASK_ROOT/build/RecognizerManualScrollChecks.swift" \
    -o "$TASK_ROOT/build/check-manual-scroll"
"$TASK_ROOT/build/check-manual-scroll"
