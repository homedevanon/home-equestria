// Shared look values (look overhaul 2026-11-10). Every look_* global and the sky values the
// world's materials share are declared here, once; world/sky_controller.gd writes them.
//   look_cloud_shadow: strength of cloud shadows on the land (0 = none: night, overcast, or
//     LOOK_CLOUD_SHADOWS off). The drift and cover are the sky's own cloud values below.
global uniform float look_cloud_shadow;
global uniform vec2 sky_cloud_offset;
global uniform vec3 sky_cloud_shape;
