// Header-only target: exposes the sherpa-onnx C API types to Swift.
// The library itself is loaded at runtime with dlopen (see KokoroVoice.swift),
// so MacPilot still launches when the voice isn't installed.
// sherpa-onnx (https://github.com/k2-fsa/sherpa-onnx) is Apache-2.0 licensed; header from v2.0.1.
#include "sherpa-onnx-c-api.h"
