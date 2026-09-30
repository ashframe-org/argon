#version 460

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 frag_color;

layout(binding = 0) uniform sampler2D icon;

void main() {
	vec4 c = texture(icon, uv);
	if (c.a == 0.0) discard;
	frag_color = c;
}
