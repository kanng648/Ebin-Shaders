attribute vec4 mc_Entity;
attribute vec4 at_tangent;
#if defined gbuffers_terrain || defined gbuffers_water
attribute vec4 mc_midTexCoord;
#endif

uniform sampler2D lightmap;

uniform mat4 gbufferModelViewInverse;

uniform vec3  cameraPosition;
uniform float frameTimeCounter;

varying vec3 color;
varying vec2 texcoord;

varying mat3 tbnMatrix;

varying mat2x3 position;

varying vec3 worldDisplacement;

varying vec2 vertLightmap;

varying float mcID;
varying float materialIDs;
varying float nightVision;

#include "/lib/Settings.glsl"
#include "/lib/Utility.glsl"
#include "/lib/Debug.glsl"
#include "/lib/Uniform/Projection_Matrices.vsh"

#if defined gbuffers_water
#include "/lib/Uniform/Shading_Variables.glsl"
#include "/lib/Uniform/Shadow_View_Matrix.vsh"
#endif


vec2 GetDefaultLightmap(vec2 lightmapCoord) {
	return clamp01((lightmapCoord * pow2(1.031)) - 0.032).rg;
}

#include "/lib/Vertex/Materials.vsh"

vec3 GetWorldSpacePosition() {
	vec3 position = transMAD(gl_ModelViewMatrix, gl_Vertex.xyz);
	
#if  defined gbuffers_water
	position -= gl_NormalMatrix * normalize(gl_Normal) * 0.00005 * float(abs(mc_Entity.x - 8.5) > 0.6);
#elif defined gbuffers_spidereyes
	position += gl_NormalMatrix * normalize(gl_Normal) * 0.0002;
#endif
	
	return mat3(gbufferModelViewInverse) * position;
}

vec4 ProjectViewSpace(vec3 viewSpacePosition) {
#if !defined gbuffers_hand
	return vec4(projMAD(projMatrix, viewSpacePosition), viewSpacePosition.z * projMatrix[2].w);
#else
	return vec4(projMAD(gl_ProjectionMatrix, viewSpacePosition), viewSpacePosition.z * gl_ProjectionMatrix[2].w);
#endif
}

#include "/lib/Vertex/Waving.vsh"
#include "/lib/Vertex/Vertex_Displacements.vsh"

mat3 CalculateTBN(vec3 worldPosition) {
	vec3 tangent  = normalize(at_tangent.xyz);
	vec3 binormal = normalize(-cross(gl_Normal, at_tangent.xyz));
	
	tangent  += CalculateVertexDisplacements(worldPosition +  tangent, vertLightmap.g) - worldDisplacement;
	binormal += CalculateVertexDisplacements(worldPosition + binormal, vertLightmap.g) - worldDisplacement;
	
	tangent  = mat3(gbufferModelViewInverse) * gl_NormalMatrix * normalize( tangent);
	binormal = mat3(gbufferModelViewInverse) * gl_NormalMatrix * normalize(binormal);
	
	vec3 normal = normalize(cross(-tangent, binormal));
	
	return mat3(tangent, binormal, normal);
}

void main() {
#ifdef HIDE_ENTITIES
	if (mc_Entity.x < 0.5) { gl_Position = vec4(-1.0); return; }
#endif
	
	SetupProjection();
	
	color        = abs(mc_Entity.x - 10.5) > 0.6 ? gl_Color.rgb : vec3(1.0);
	texcoord     = gl_MultiTexCoord0.st;
	mcID         = mc_Entity.x;
	vertLightmap = GetDefaultLightmap(mat2(gl_TextureMatrix[1]) * gl_MultiTexCoord1.st);
	materialIDs  = GetMaterialIDs(int(mc_Entity.x));
	
#ifdef NIGHTVISION
	nightVision = float(texture2D(lightmap, vec2(0.0)).r > 0.2);
#else
	nightVision = 0.0;
#endif
	
	
	vec3 worldSpacePosition = GetWorldSpacePosition();
	
	worldDisplacement = CalculateVertexDisplacements(worldSpacePosition, vertLightmap.g);
	
	position[1] = worldSpacePosition + worldDisplacement;
	position[0] = position[1] * mat3(gbufferModelViewInverse);
	
	gl_Position = ProjectViewSpace(position[0]);
	
	
	tbnMatrix   = CalculateTBN(worldSpacePosition);
	
	
#if defined gbuffers_water
	#include "/lib/Vertex/Shading_Setup.vsh"
#endif
	
	
	exit();
}
