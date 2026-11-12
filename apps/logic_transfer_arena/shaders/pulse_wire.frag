#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uTension;     // 0.0 normal -> 1.0 final 5s / overtime pulse
uniform float uPortrait;    // 0.0 landscape, 1.0 transposed portrait

out vec4 fragColor;

void main() {
  vec2 pos = FlutterFragCoord().xy;
  vec2 uv = pos / max(uSize, vec2(1.0));

  // Deep etched silicon substrate with subtle cyan/amber territory bias.
  vec3 base = vec3(0.035, 0.050, 0.078);

  float sideAxis = mix(uv.x, 1.0 - uv.y, uPortrait);
  vec3 cyanTint = vec3(0.00, 0.24, 0.30) * smoothstep(0.45, 0.0, sideAxis) * 0.22;
  vec3 amberTint = vec3(0.30, 0.17, 0.00) * smoothstep(0.55, 1.0, sideAxis) * 0.22;

  // Central Bus energy spine harmonic glow.
  float busDist = abs(sideAxis - 0.5);
  float spineWave = 0.5 + 0.5 * sin(uTime * 3.2 - uv.y * 10.0);
  vec3 spineGlow = vec3(0.06, 0.14, 0.22) * exp(-busDist * 28.0) * (0.65 + 0.35 * spineWave);

  // Micro-etched PCB copper trace grain (non-grid organic substrate depth).
  float scan = sin(pos.y * 1.57) * 0.008;
  float heartbeat = uTension * (0.5 + 0.5 * sin(uTime * 11.0));
  float edgeVignette = smoothstep(0.28, 0.95, length((uv - 0.5) * vec2(1.35, 1.35)));
  vec3 tensionRim = vec3(0.32, 0.08, 0.04) * edgeVignette * heartbeat * 0.55;

  vec3 col = base + cyanTint + amberTint + spineGlow + tensionRim + scan;
  fragColor = vec4(col, 1.0);
}
