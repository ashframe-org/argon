#version 460

layout(location = 0) in vec2 vertex_pos;

layout(location = 0) out vec2 uv;

#ifdef OPEN_GL
layout(location = 0) uniform vec2 start; // sign-texture pixels, top-left origin
layout(location = 1) uniform vec2 size;
layout(location = 2) uniform vec2 screen; // sign canvas size in pixels
#else
layout(push_constant, std430) uniform _ {
	vec2 start;
	vec2 size;
	vec2 screen;
};
#endif

void main() {
	// Pixel -> NDC, top-left origin, matching the sign framebuffer.
	vec2 p = (start + vec2(vertex_pos.x*size.x, vertex_pos.y*size.y))/screen;
	gl_Position = vec4(p.x*2.0 - 1.0, 1.0 - p.y*2.0, 0.0, 1.0);
	uv = vec2(vertex_pos.x, vertex_pos.y);
}
