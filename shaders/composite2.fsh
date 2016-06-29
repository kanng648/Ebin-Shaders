#version 410 compatibility
#define composite2
#define fsh
#define ShaderStage 2
#include "/lib/Syntax.glsl"


/* DRAWBUFFERS:6 */

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;
uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D gdepthtex;
uniform sampler2D depthtex1;
uniform sampler2D noisetex;
uniform sampler2DShadow shadow; 

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;

uniform vec3 cameraPosition;

uniform float frameTimeCounter;
uniform float rainStrength;

uniform float viewWidth;
uniform float viewHeight;

uniform float near;
uniform float far;

uniform int isEyeInWater;

varying vec2 texcoord;

#include "/lib/Settings.glsl"
#include "/lib/Utility.glsl"
#include "/lib/DebugSetup.glsl"
#include "/lib/Uniform/GlobalCompositeVariables.glsl"
#include "/lib/Fragment/Masks.fsh"
#include "/lib/Misc/CalculateFogFactor.glsl"
#include "/lib/Fragment/ReflectanceModel.fsh"

const bool colortex5MipmapEnabled = true;


vec3 GetColor(in vec2 coord) {
	return DecodeColor(texture2D(colortex5, coord).rgb);
}

vec3 GetColorLod(in vec2 coord, in float lod) {
	return DecodeColor(texture2DLod(colortex5, coord, lod).rgb);
}

float GetDepth(in vec2 coord) {
	return texture2D(gdepthtex, coord).x;
}

float GetTransparentDepth(in vec2 coord) {
	return texture2D(depthtex1, coord).x;
}

float ExpToLinearDepth(in float depth) {
	return 2.0 * near * (far + near - depth * (far - near));
}

vec4 CalculateViewSpacePosition(in vec2 coord, in float depth) {
	vec4 position  = gbufferProjectionInverse * vec4(vec3(coord, depth) * 2.0 - 1.0, 1.0);
	     position /= position.w;
	
	return position;
}

vec3 ViewSpaceToScreenSpace(vec3 viewSpacePosition) {
	vec4 screenSpace = gbufferProjection * vec4(viewSpacePosition, 1.0);
	
	return (screenSpace.xyz / screenSpace.w) * 0.5 + 0.5;
}

vec3 ViewSpaceToScreenSpace(vec4 viewSpacePosition) {
	vec4 screenSpace = gbufferProjection * viewSpacePosition;
	
	return (screenSpace.xyz / screenSpace.w) * 0.5 + 0.5;
}

vec3 GetNormal(in vec2 coord) {
	return DecodeNormal(texture2D(colortex6, coord).xy);
}

#include "/lib/Misc/DecodeBuffer.fsh"


float GetVolumetricFog(in vec2 coord) {
#ifdef VOLUMETRIC_FOG
	return texture2D(colortex7, coord).a;
#endif
	
	return 1.0;
}

float noise(in vec2 coord) {
    return fract(sin(dot(coord, vec2(12.9898, 4.1414))) * 43758.5453);
}


#include "/lib/Fragment/WaterWaves.fsh"

#include "/lib/Fragment/CalculateShadedFragment.fsh"

#include "/lib/Fragment/Sky.fsh"

bool ComputeRaytracedIntersection(in vec3 startingViewPosition, in vec3 rayDirection, in float firstStepSize, cfloat rayGrowth, cint maxSteps, cint maxRefinements, out vec3 screenSpacePosition, out vec4 viewSpacePosition) {
	vec3 rayStep = rayDirection * firstStepSize;
	vec4 ray = vec4(startingViewPosition + rayStep, 1.0);
	
	screenSpacePosition = ViewSpaceToScreenSpace(ray);
	
	float refinements = 0;
	float refinementCoeff = 1.0;
	
	cbool doRefinements = (maxRefinements > 0);
	
	float maxRayDepth = -(far * 1.6 + 16.0);
	
	for (int i = 0; i < maxSteps; i++) {
		if (any(greaterThan(abs(screenSpacePosition.xyz - 0.5), vec3(0.5))) || ray.z < maxRayDepth)
			return false;
		
		float sampleDepth = GetTransparentDepth(screenSpacePosition.st);
		
		viewSpacePosition = CalculateViewSpacePosition(screenSpacePosition.st, sampleDepth);
		
		float diff = viewSpacePosition.z - ray.z;
		
		if (diff >= 0) {
			if (doRefinements) {
				float error = firstStepSize * pow(rayGrowth, i) * refinementCoeff;
				
				if(diff <= error * 2.0 && refinements <= maxRefinements) {
					ray.xyz -= rayStep * refinementCoeff;
					refinementCoeff = 1.0 / exp2(++refinements);
				} else if (diff <= error * 4.0 && refinements > maxRefinements) {
					screenSpacePosition.z = sampleDepth;
					return true;
				}
			}
			
			else return true;
		}
		
		ray.xyz += rayStep * refinementCoeff;
		
		rayStep *= rayGrowth;
		
		screenSpacePosition = ViewSpaceToScreenSpace(ray);
	}
	
	return false;
}

#ifndef PBR
void ComputeReflectedLight(inout vec3 color, in vec4 viewSpacePosition, in vec3 normal, in float smoothness, in float skyLightmap, in Mask mask) {
	if (mask.water < 0.5) smoothness = pow(smoothness, 4.8);
	
	vec3  rayDirection  = normalize(reflect(viewSpacePosition.xyz, normal));
	float firstStepSize = mix(1.0, 30.0, pow2(length((gbufferModelViewInverse * viewSpacePosition).xz) / 144.0));
	vec3  reflectedCoord;
	vec4  reflectedViewSpacePosition;
	vec3  reflection;
	
	float roughness = 1.0 - smoothness;
	
	float vdoth   = clamp01(dot(-normalize(viewSpacePosition.xyz), normal));
	vec3  sColor  = mix(vec3(0.15), color * 0.2, vec3(mask.metallic));
	vec3  fresnel = Fresnel(sColor, vdoth);
	
	vec3 alpha = fresnel * smoothness;
	
	if (length(alpha) < 0.01) return;
	
	
	float sunlight = ComputeShadows(viewSpacePosition, 1.0);
	
	vec3 reflectedSky  = CalculateSky(vec4(reflect(viewSpacePosition.xyz, normal), 1.0), false);
	     reflectedSky *= 1.0;
	
	vec3 reflectedSunspot = CalculateSpecularHighlight(lightVector, normal, fresnel, -normalize(viewSpacePosition.xyz), roughness) * sunlight;
	
	vec3 offscreen = reflectedSky + reflectedSunspot * sunlightColor * 100.0;
	
	if (!ComputeRaytracedIntersection(viewSpacePosition.xyz, rayDirection, firstStepSize, 1.3, 30, 3, reflectedCoord, reflectedViewSpacePosition))
		reflection = offscreen;
	else {
		reflection = GetColor(reflectedCoord.st);
		
		vec3 reflectionVector = normalize(reflectedViewSpacePosition.xyz - viewSpacePosition.xyz) * length(reflectedViewSpacePosition.xyz); // This is not based on any physical property, it just looked around when I was toying around
		
		CompositeFog(reflection, vec4(reflectionVector, 1.0), GetVolumetricFog(reflectedCoord.st));
		
		#ifdef REFLECTION_EDGE_FALLOFF
			float angleCoeff = clamp(pow(dot(vec3(0.0, 0.0, 1.0), normal) + 0.15, 0.25) * 2.0, 0.0, 1.0) * 0.2 + 0.8;
			float dist       = length8(abs(reflectedCoord.xy - vec2(0.5)));
			float edge       = clamp(1.0 - pow2(dist * 2.0 * angleCoeff), 0.0, 1.0);
			reflection       = mix(reflection, reflectedSky, pow(1.0 - edge, 10.0));
		#endif
	}
	
	color = mix(color, reflection, alpha);
}

#else
void ComputeReflectedLight(inout vec3 color, in vec4 viewSpacePosition, in vec3 normal, in float smoothness, in float skyLightmap, in Mask mask) {
	if (mask.water < 0.5) smoothness = pow(smoothness, 4.8);
	
	float firstStepSize = mix(1.0, 30.0, pow2(length((gbufferModelViewInverse * viewSpacePosition).xz) / 144.0));
	vec3  reflectedCoord;
	vec4  reflectedViewSpacePosition;
	vec3  reflection;
	
	float roughness = 1.0 - smoothness;
	
	#define IOR 0.15 // [0.05 0.1 0.15 0.25 0.5]
	
	float vdoth   = clamp01(dot(-normalize(viewSpacePosition.xyz), normal));
	vec3  sColor  = mix(vec3(IOR), clamp(color * 0.25, 0.02, 0.99), vec3(mask.metallic));
	vec3  fresnel = Fresnel(sColor, vdoth);
	
	vec3 alpha = fresnel * smoothness;
	if(mask.metallic > 0.1) alpha = sColor;
	
	//This breaks some things.
	//if (length(alpha) < 0.01) return;
	
	float sunlight = ComputeShadows(viewSpacePosition, 1.0);
	
	vec3 reflectedSky  = CalculateSky(vec4(reflect(viewSpacePosition.xyz, normal), 1.0), false);
	vec3 reflectedSunspot = CalculateSpecularHighlight(lightVector, normal, fresnel, -normalize(viewSpacePosition.xyz), roughness) * sunlight;
	
	vec3 offscreen = (reflectedSky + reflectedSunspot * sunlightColor * 100.0);
	if(mask.metallic > 0.5) offscreen *= smoothness + 0.1;
	
	for (uint i = 1; i <= PBR_RAYS; i++) {
		vec2 epsilon = vec2(noise(texcoord * (i + 1)), noise(texcoord * (i + 1) * 3));
		vec3 BRDFSkew = skew(epsilon, pow2(roughness));
		
		vec3 reflectDir  = normalize(BRDFSkew * roughness / 8.0 + normal);
		     reflectDir *= sign(dot(normal, reflectDir));
		
		vec3 rayDirection = reflect(normalize(viewSpacePosition.xyz), reflectDir);
		
		if (!ComputeRaytracedIntersection(viewSpacePosition.xyz, rayDirection, firstStepSize, 1.3, 30, 3, reflectedCoord, reflectedViewSpacePosition)) { //this is much faster I tested
			reflection += offscreen + 0.5 * mask.metallic;
		} else {
			vec3 reflectionVector = normalize(reflectedViewSpacePosition.xyz - viewSpacePosition.xyz) * length(reflectedViewSpacePosition.xyz); // This is not based on any physical property, it just looked around when I was toying around
			// Maybe give previous reflection Intersection to make sure we dont compute rays in the same pixel twice.
			
			vec3 colorSample = GetColorLod(reflectedCoord.st, 2);
			
			CompositeFog(colorSample, vec4(reflectionVector, 1.0), GetVolumetricFog(reflectedCoord.st));
			
			#ifdef REFLECTION_EDGE_FALLOFF
				float angleCoeff = clamp(pow(dot(vec3(0.0, 0.0, 1.0), normal) + 0.15, 0.25) * 2.0, 0.0, 1.0) * 0.2 + 0.8;
				float dist       = length8(abs(reflectedCoord.xy - vec2(0.5)));
				float edge       = clamp(1.0 - pow2(dist * 2.0 * angleCoeff), 0.0, 1.0);
				colorSample      = mix(colorSample, reflectedSky, pow(1.0 - edge, 10.0));
			#endif
			
			reflection += colorSample;
		}
	}
	
	reflection /= PBR_RAYS;
	
	color = mix(color * (1.0 - mask.metallic), reflection, alpha);
}
#endif

mat3 GetWaterTBN() {
	vec3 normal = DecodeNormal(texture2D(colortex1, texcoord).xy);
	
	vec3 worldNormal = normalize((gbufferModelViewInverse * vec4(normal, 0.0)).xyz);
	
	vec3 y = cross(worldNormal, vec3(0.0, 1.0, 0.0));
	vec3 z = cross(worldNormal, vec3(0.0, 0.0, 1.0));
	
	vec3 tangent = (length(y) > length(z) ? y : z);
	
	tangent = normalize((gbufferModelView * vec4(tangent, 0.0)).xyz);
	
	vec3 binormal = normalize(cross(normal, tangent));
	
	return transpose(mat3(tangent, binormal, normal));
}

void AddWater(in vec4 viewSpacePosition, inout Mask mask, out vec3 color, out vec3 normal, out float smoothness, out vec3 tangentNormal) {
	mask.metallic = 0.0;
	color         = vec3(0.0, 0.015, 0.2);
	smoothness    = 0.85;
	
	mat3 tbnMatrix = GetWaterTBN();
	tangentNormal  = GetWaveNormals(viewSpacePosition, transpose(tbnMatrix)[2]);
	normal         = normalize(tangentNormal * tbnMatrix);
}

vec3 GetRefractedColor(in vec2 coord, in vec4 viewSpacePosition, in vec4 viewSpacePosition1, in vec3 normal, in vec3 tangentNormal) {
	vec4 screenSpacePosition = gbufferProjection * viewSpacePosition;
	
	float fov = atan(1.0 / gbufferProjection[1].y) * 2.0 / RAD;
	
	float VdotN        = dot(-normalize(viewSpacePosition.xyz), normalize(normal));
	float surfaceDepth = sqrt(length(viewSpacePosition1.xyz - viewSpacePosition.xyz)) * VdotN;
	
	cfloat refractAmount = 0.5;
	cfloat aberrationAmount = 1.0 + 0.2;
	
	vec2 refraction = tangentNormal.st / fov * 90.0 * refractAmount * min(surfaceDepth, 1.0);
	
	mat3x2 coords = mat3x2(screenSpacePosition.st + refraction * aberrationAmount,
	                       screenSpacePosition.st + refraction,
	                       screenSpacePosition.st + refraction);
	
	coords = coords / screenSpacePosition.w * 0.5 + 0.5;
	
	vec2 pixelSize = 1.0 / vec2(viewWidth, viewHeight);
	vec2 minCoord  = pixelSize;
	vec2 maxCoord  = 1.0 - pixelSize;
	
	coords[0] = clamp(coords[0], minCoord, maxCoord);
	coords[1] = clamp(coords[1], minCoord, maxCoord);
	coords[2] = clamp(coords[2], minCoord, maxCoord);
	
	vec3 color = vec3(texture2D(colortex5, coords[0]).r,
	                  texture2D(colortex5, coords[1]).g,
	                  texture2D(colortex5, coords[2]).b);
	
	return DecodeColor(color);
}

vec3 CompositeWater(in vec3 color, in vec3 color1, in float depth1, in float waterMask) {
	return mix(color, color1, 0.4);
}

void GetSurfaceProperties(in Mask mask, out vec3 normal, out vec3 color0, out vec3 color1) {
	if (mask.transparent < 0.5) {
		// Solid
	} else if (mask.water < 0.5) {
		// Transparent non-water
	} else {
		// Water
	}
}

void DecodeTransparentBuffer(in vec2 coord, out float buffer0r, out float buffer0g, out float buffer1r) {
	vec2 encode = texture2D(colortex2, coord).rg;
	
	vec2 buffer0 = Decode16(encode.r);
	buffer0r = buffer0.r;
	buffer0g = buffer0.g;
	
	vec2 buffer1 = Decode16(encode.g);
	buffer1r = buffer1.r;
}



void main() {
	float depth0 = GetDepth(texcoord);
	vec4 viewSpacePosition0 = CalculateViewSpacePosition(texcoord, depth0);
	
	
	if (depth0 >= 1.0) { gl_FragData[0] = vec4(EncodeColor(CalculateSky(viewSpacePosition0, true)), 1.0); exit(); return; }
	
	
	vec3 encode; float torchLightmap, skyLightmap, smoothness; Mask mask;
	DecodeBuffer(texcoord, encode, torchLightmap, skyLightmap, smoothness, mask.materialIDs);
	
	mask = CalculateMasks(mask);
	
	float depth1 = depth0;
	vec4  viewSpacePosition1 = vec4(1.0);
	
	if (mask.transparent > 0.5) {
		depth1             = GetTransparentDepth(texcoord);
		viewSpacePosition1 = CalculateViewSpacePosition(texcoord, depth1);
	}
	
	
	vec3 normal = vec3(0.0, 0.0, 1.0);
	vec3 tangentNormal = vec3(0.0, 0.0, 1.0);
	vec3 color0 = vec3(0.0);
	vec3 color1 = vec3(0.0);
	
//	GetSurfaceProperties(normal, color0, color1);
	
	if (mask.transparent > 0.5) {
		DecodeTransparentBuffer(texcoord, torchLightmap, skyLightmap, smoothness);
		mask.grass = 0.0;
		mask.leaves = 0.0;
		
		vec3 tangentNormal;
		mat3 tbnMatrix;
		
		tbnMatrix[0] = DecodeNormal(texture2D(colortex0, texcoord).xy);
		tbnMatrix[2] = DecodeNormal(texture2D(colortex1, texcoord).xy);
		tbnMatrix[1] = normalize(cross(tbnMatrix[2], tbnMatrix[0]));
		
		if (mask.water > 0.5) {
			tangentNormal = GetWaveNormals(viewSpacePosition0, tbnMatrix[2]);
			smoothness = 0.85;
		} else {
			tangentNormal = DecodeNormal(vec2(texture2D(colortex0, texcoord).z, texture2D(colortex1, texcoord).z));
		}
		
	//	tangentNormal = vec3(0.0, 0.0, 1.0);
		
		normal = normalize(tangentNormal * transpose(tbnMatrix));
		
		color1 = GetRefractedColor(texcoord, viewSpacePosition0, viewSpacePosition1, normal, tangentNormal);
		color0 = pow(texture2D(colortex3, texcoord).rgb, vec3(2.2));
		color0 *= CalculateShadedFragment(mask, torchLightmap, skyLightmap, normal, smoothness, viewSpacePosition0);
		
	} else {
		normal = GetNormal(texcoord);
		color0 = DecodeColor(texture2D(colortex5, texcoord).rgb);
		color1 = color0;
	}
	
	
	ComputeReflectedLight(color0, viewSpacePosition0, normal, smoothness, skyLightmap, mask);
	
	
	if (depth1 >= 1.0) color0 = mix(CalculateSky(viewSpacePosition0, true), color0, texture2D(colortex4, texcoord).r);
	else if (mask.transparent > 0.5) color0 = mix(color1, color0, texture2D(colortex4, texcoord).r);
	
	
	CompositeFog(color0, viewSpacePosition0, GetVolumetricFog(texcoord));
	
	
	gl_FragData[0] = vec4(EncodeColor(color0), 1.0);
	
	exit();
}
