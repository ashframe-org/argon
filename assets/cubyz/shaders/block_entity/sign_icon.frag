#version 460

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 frag_color;

layout(binding = 0) uniform sampler2D icon;

void main() {
	vec4 c = texture(icon, uv);
	if (c.a == 0.0) discard;
	// generateBlockTexture clears transparent blocks with an opaque grey
	// (0.683,0.685,0.685) — fine in the inventory slot, but it reads as a
	// background box on a sign. Key it out so glass/ice icons are clean.
	if (abs(c.r - 0.683) < 0.02 && abs(c.g - 0.685) < 0.02 && abs(c.b - 0.685) < 0.02 && c.a > 0.99) discard;
	frag_color = c;
}
