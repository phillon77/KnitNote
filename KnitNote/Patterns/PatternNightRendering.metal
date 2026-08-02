#include <metal_stdlib>
using namespace metal;

[[ stitchable ]] half4 patternNightColorInvert(float2 position, half4 color) {
    return half4(half3(1.0h) - color.rgb, color.a);
}
