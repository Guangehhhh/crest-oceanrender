// This file is subject to the MIT License as seen in the root of this folder structure (LICENSE)

Shader "Ocean/Ocean"
{
	Properties
	{
		[NoScaleOffset] _Normals ( "Normals", 2D ) = "bump" {}
		_NormalsStrength("Normals Strength", Range(0.0, 2.0)) = 0.3
		_NormalsScale("Normals Scale", Range(0.0, 50.0)) = 1.0
		[NoScaleOffset] _Skybox ("Skybox", CUBE) = "" {}
		_Diffuse("Diffuse", Color) = (0.2, 0.05, 0.05, 1.0)
		_SubSurface("Sub-Surface Scattering", Color) = (0.0, 0.48, 0.36, 1.)
		[NoScaleOffset] _FoamTexture ( "Foam Texture", 2D ) = "white" {}
		_FoamScale("Foam Scale", Range(0.0, 50.0)) = 10.0
		_FoamWhiteColor("White Foam Color", Color) = (1.0, 1.0, 1.0, 1.0)
		_FoamBubbleColor ( "Bubble Foam Color", Color ) = (0.0, 0.0904, 0.105, 1.0)
		_DepthFogDensity("Depth Fog Density", Color) = (0.28, 0.16, 0.24, 1.0)
		_FresnelPower("Fresnel Power", Range(0.0,20.0)) = 3.0
	}

	Category
	{
		Tags {}

		SubShader
		{
			// this sorts back to front due to transparent i guess, perhaps set queue to Geometry+1?
			Tags { "LightMode"="Always" "Queue"="Transparent" "IgnoreProjector"="True" "RenderType"="Opaque" }

			GrabPass
			{
				"_BackgroundTexture"
			}

			Pass
			{
				CGPROGRAM
				#pragma vertex vert
				#pragma fragment frag
				#pragma multi_compile_fog
				#include "UnityCG.cginc"
				#include "TextureBombing.cginc"

				// tints the output color based on which shape texture(s) were sampled, blended according to weight
				//#define DEBUG_SHAPE_SAMPLE
				#define DEPTH_BIAS 100.

				struct appdata_t
				{
					float4 vertex : POSITION;
					float2 texcoord: TEXCOORD0;
				};

				struct v2f
				{
					float4 vertex : SV_POSITION;
					half3 n : TEXCOORD1;
					half shorelineFoam : TEXCOORD4;
					half4 invDeterminant_lodAlpha_worldXZUndisplaced : TEXCOORD5;
					float3 worldPos : TEXCOORD7;
					#if defined( DEBUG_SHAPE_SAMPLE )
					half3 debugtint : TEXCOORD8;
					#endif

					UNITY_FOG_COORDS( 3 )
				};

				// GLOBAL PARAMS

				#include "OceanLODData.cginc"

				uniform float3 _OceanCenterPosWorld;
				uniform float _EnableSmoothLODs = 1.0; // debug

				// INSTANCE PARAMS

				// Geometry data
				// x: A square is formed by 2 triangles in the mesh. Here x is square size
				// yz: normalScrollSpeed0, normalScrollSpeed1
				// w: Geometry density - side length of patch measured in squares
				uniform float4 _GeomData;

				// MeshScaleLerp, FarNormalsWeight, LODIndex (debug), unused
				uniform float4 _InstanceData;

				// sample wave or terrain height, with smooth blend towards edges.
				// would equally apply to heights instead of displacements.
				// this could be optimized further.
				void SampleDisplacements( in sampler2D i_dispSampler, in sampler2D i_oceanDepthSampler, in float2 i_centerPos, in float i_res, in float i_texelSize, in float i_geomSquareSize, in float2 i_samplePos, in float wt, inout float3 io_worldPos, inout float3 io_n, inout float io_determinant, inout half io_shorelineFoam )
				{
					if( wt < 0.001 )
						return;

					float4 uv = float4(WD_worldToUV(i_samplePos, i_centerPos, i_res, i_texelSize), 0., 0.);

					// do computations for hi-res
					float3 dd = float3(i_geomSquareSize / (i_texelSize*i_res), 0.0, i_geomSquareSize);
					float4 s = tex2Dlod(i_dispSampler, uv);
					float4 sx = tex2Dlod(i_dispSampler, uv + dd.xyyy);
					float4 sz = tex2Dlod(i_dispSampler, uv + dd.yxyy);
					float3 disp = s.xyz;
					float3 disp_x = dd.zyy + sx.xyz;
					float3 disp_z = dd.yyz + sz.xyz;
					io_worldPos += wt * disp;

					float3 n = normalize( cross( disp_z - disp, disp_x - disp ) );
					io_n.xz += wt * n.xz;

					// The determinant of the displacement Jacobian is a good measure for turbulence:
					// > 1: Stretch
					// < 1: Squash
					// < 0: Overlap
					float4 du = float4(disp_x.xz, disp_z.xz) - disp.xzxz;
					float det = (du.x * du.w - du.y * du.z) / (dd.z * dd.z);
					// actually store 1-determinant. This means that when far lod is faded out to 0, this tends to make foam and scatter color etc fade out, instead of getting stronger.
					det = 1. - det;
					io_determinant += wt * det;

					// foam from shallow water - signed depth is depth compared to sea level, plus wave height. depth bias is an optimisation
					// which allows the depth data to be initialised once to 0 without generating foam everywhere.
					half signedDepth = (tex2Dlod(i_oceanDepthSampler, uv).x + DEPTH_BIAS) + disp.y ;
					io_shorelineFoam += wt * clamp( 1. - signedDepth / 1.5, 0., 1.);
				}

				v2f vert( appdata_t v )
				{
					v2f o;

					// see comments above on _GeomData
					const float SQUARE_SIZE = _GeomData.x, SQUARE_SIZE_2 = 2.0*_GeomData.x, SQUARE_SIZE_4 = 4.0*_GeomData.x;
					const float BASE_DENSITY = _GeomData.w;

					// move to world
					o.worldPos = mul( unity_ObjectToWorld, v.vertex );
	
					// snap the verts to the grid
					// The snap size should be twice the original size to keep the shape of the eight triangles (otherwise the edge layout changes).
					o.worldPos.xz -= frac(_OceanCenterPosWorld.xz / SQUARE_SIZE_2) * SQUARE_SIZE_2; // caution - sign of frac might change in non-hlsl shaders
	
					// how far are we into the current LOD? compute by comparing the desired square size with the actual square size
					float2 offsetFromCenter = float2( abs( o.worldPos.x - _OceanCenterPosWorld.x ), abs( o.worldPos.z - _OceanCenterPosWorld.z ) );
					float taxicab_norm = max( offsetFromCenter.x, offsetFromCenter.y );
					float idealSquareSize = taxicab_norm / BASE_DENSITY;
					// this is to address numerical issues with the normal (errors are very visible at close ups of specular highlights).
					// i original had this max( .., SQUARE_SIZE ) but there were still numerical issues and a pop when changing camera height.
					idealSquareSize = max( idealSquareSize, 0.03125 );

					// interpolation factor to next lod (lower density / higher sampling period)
					float lodAlpha = idealSquareSize/SQUARE_SIZE - 1.0;
					// lod alpha is remapped to ensure patches weld together properly. patches can vary significantly in shape (with
					// strips added and removed), and this variance depends on the base density of the mesh, as this defines the strip width.
					// using .15 as black and .85 as white should work for base mesh density as low as 16. TODO - make this automatic?
					const float BLACK_POINT = 0.15, WHITE_POINT = 0.85;
					lodAlpha = max( (lodAlpha - BLACK_POINT) / (WHITE_POINT-BLACK_POINT), 0. );
					// blend out lod0 when viewpoint gains altitude
					const float meshScaleLerp = _InstanceData.x;
					lodAlpha = min(lodAlpha + meshScaleLerp, 1.);
					lodAlpha *= _EnableSmoothLODs;
					// pass it to fragment shader - used to blend normals scales
					o.invDeterminant_lodAlpha_worldXZUndisplaced.y = lodAlpha;


					// now smoothly transition vert layouts between lod levels - move interior verts inwards towards center
					float2 m = frac( o.worldPos.xz / SQUARE_SIZE_4 ); // this always returns positive
					float2 offset = m - 0.5;
					// check if vert is within one square from the center point which the verts move towards
					const float minRadius = 0.26; //0.26 is 0.25 plus a small "epsilon" - should solve numerical issues
					if( abs( offset.x ) < minRadius ) o.worldPos.x += offset.x * lodAlpha * SQUARE_SIZE_4;
					if( abs( offset.y ) < minRadius ) o.worldPos.z += offset.y * lodAlpha * SQUARE_SIZE_4;
					o.invDeterminant_lodAlpha_worldXZUndisplaced.zw = o.worldPos.xz;


					// sample shape textures - always lerp between 2 scales, so sample two textures
					o.n = half3(0., 1., 0.);
					o.invDeterminant_lodAlpha_worldXZUndisplaced.x = 0.;
					o.shorelineFoam = 0.;
					// sample weights. params.z allows shape to be faded out (used on last lod to support pop-less scale transitions)
					float wt_0 = (1. - lodAlpha) * _WD_Params_0.z;
					float wt_1 = (1. - wt_0) * _WD_Params_1.z;
					// sample displacement textures, add results to current world pos / normal / foam
					const float2 wxz = o.worldPos.xz;
					SampleDisplacements( _WD_Sampler_0, _WD_OceanDepth_Sampler_0, _WD_Pos_0, _WD_Params_0.y, _WD_Params_0.x, idealSquareSize, wxz, wt_0, o.worldPos, o.n, o.invDeterminant_lodAlpha_worldXZUndisplaced.x, o.shorelineFoam);
					SampleDisplacements( _WD_Sampler_1, _WD_OceanDepth_Sampler_1, _WD_Pos_1, _WD_Params_1.y, _WD_Params_1.x, idealSquareSize, wxz, wt_1, o.worldPos, o.n, o.invDeterminant_lodAlpha_worldXZUndisplaced.x, o.shorelineFoam);

					// debug tinting to see which shape textures are used
					#if defined( DEBUG_SHAPE_SAMPLE )
					#define TINT_COUNT (uint)7
					half3 tintCols[TINT_COUNT]; tintCols[0] = half3(1., 0., 0.); tintCols[1] = half3(1., 1., 0.); tintCols[2] = half3(1., 0., 1.); tintCols[3] = half3(0., 1., 1.); tintCols[4] = half3(0., 0., 1.); tintCols[5] = half3(1., 0., 1.); tintCols[6] = half3(.5, .5, 1.);
					o.debugtint = wt_0 * tintCols[_WD_LodIdx_0 % TINT_COUNT] + wt_1 * tintCols[_WD_LodIdx_1 % TINT_COUNT];
					#endif


					// view-projection	
					o.vertex = mul(UNITY_MATRIX_VP, float4(o.worldPos, 1.));

					UNITY_TRANSFER_FOG(o, o.vertex);

					return o;
				}

				// frag shader uniforms
				uniform half4 _Diffuse;
				uniform half4 _SubSurface;
				uniform half4 _DepthFogDensity;
				uniform samplerCUBE _Skybox;
				uniform sampler2D _FoamTexture;
				uniform half4 _FoamWhiteColor;
				uniform half4 _FoamBubbleColor;
				uniform sampler2D _Normals;
				uniform half _NormalsStrength;
				uniform half _NormalsScale;
				uniform half _FoamScale;
				uniform half _FresnelPower;
				uniform float _MyTime;

				// these are copied from the render target by unity
				sampler2D _BackgroundTexture;
				sampler2D _CameraDepthTexture;

				void ApplyNormalMaps(float2 worldXZUndisplaced, float lodAlpha, inout half3 io_n )
				{
					const float2 v0 = float2(0.94, 0.34), v1 = float2(-0.85, -0.53);
					const float geomSquareSize = _GeomData.x;
					float nstretch = _NormalsScale * geomSquareSize; // normals scaled with geometry
					const float spdmulL = _GeomData.y;
					half2 norm =
						UnpackNormal(tex2D( _Normals, (v0*_MyTime*spdmulL + worldXZUndisplaced) / nstretch )).xy +
						UnpackNormal(tex2D( _Normals, (v1*_MyTime*spdmulL + worldXZUndisplaced) / nstretch )).xy;

					// blend in next higher scale of normals to obtain continuity
					const float farNormalsWeight = _InstanceData.y;
					const half nblend = lodAlpha * farNormalsWeight;
					if( nblend > 0.001 )
					{
						// next lod level
						nstretch *= 2.;
						const float spdmulH = _GeomData.z;
						norm = lerp( norm,
							UnpackNormal(tex2D( _Normals, (v0*_MyTime*spdmulH + worldXZUndisplaced) / nstretch )).xy +
							UnpackNormal(tex2D( _Normals, (v1*_MyTime*spdmulH + worldXZUndisplaced) / nstretch )).xy,
							nblend );
					}

					// approximate combine of normals. would be better if normals applied in local frame.
					io_n.xz += _NormalsStrength * norm;
					io_n = normalize(io_n);
				}

				void ApplyFoam( half i_determinant, float2 i_worldXZUndisplaced, half3 i_n, half i_shorelineFoam, inout half3 io_col, inout float io_whiteFoam )
				{
					// Give the foam some texture
					float2 foamUV = i_worldXZUndisplaced / _FoamScale;
					foamUV += 0.02 * i_n.xz;

					//half foamTexValue = textureNoTile_3weights(_FoamTexture, foamUV).r; // texture bombing to avoid repetition artifacts
					half foamTexValue = texture(_FoamTexture, foamUV).r;
					half bubbleFoamTexValue = texture(_FoamTexture, .37 * foamUV).r;

					// compute foam amount from determinant
					// > 1: Stretch
					// < 1: Squash
					// < 0: Overlap
					float foamAmount = smoothstep(1.6, 0., i_determinant);
					foamAmount = foamAmount + i_shorelineFoam;

					// Additive underwater foam
					half bubbleFoam = smoothstep( 0.0, 0.5, foamAmount * bubbleFoamTexValue);
					io_col.xyz += bubbleFoam * _FoamBubbleColor.rgb * _FoamBubbleColor.a;

					// White foam on top, with black-point fading
					io_whiteFoam = foamTexValue * (smoothstep(1.0 - foamAmount, 1.3 - foamAmount, foamTexValue)) * _FoamWhiteColor.a;
				}

				void OceanColour(half3 view, half3 n, half2 uvScreen, float z01, inout half3 oceanCol)
				{
					// Refraction - perturb screen uv, 
					half2 uvRefract = uvScreen + .02 * n.xz;
					half3 alpha = (half3)1.;

					float pixelZ = LinearEyeDepth(z01);
					float sceneZ = LinearEyeDepth(texture(_CameraDepthTexture, half2(uvScreen.x, 1. - uvScreen.y)).x);

					// if we haven't refracted onto a surface in front of the water surface, compute an alpha based on Z delta
					if (sceneZ > pixelZ)
					{
						float sceneZRefract = LinearEyeDepth(texture(_CameraDepthTexture, half2(uvRefract.x, 1. - uvRefract.y)).x);
						float maxZ = max(sceneZ, sceneZRefract);
						float deltaZ = (maxZ - pixelZ);
						alpha = 1. - exp(-_DepthFogDensity.xyz * deltaZ);
					}

					half3 sceneColour = texture(_BackgroundTexture, uvRefract).rgb;
					oceanCol = lerp(sceneColour, oceanCol, alpha);
				}

				half3 frag(v2f i) : SV_Target
				{
					half3 view = normalize(_WorldSpaceCameraPos - i.worldPos);

					// Normal - geom + normal mapping
					half3 n = i.n;
					ApplyNormalMaps(i.invDeterminant_lodAlpha_worldXZUndisplaced.zw, i.invDeterminant_lodAlpha_worldXZUndisplaced.y, n);

					// Emitted light - ocean colour
					half3 col = _Diffuse;
					// Approximate subsurface scattering - add light when surface faces viewer
					col += dot(n, view) * _SubSurface;

					// Foam - underwater bubbles and whitefoam
					float whiteFoam;
					ApplyFoam( 1. - i.invDeterminant_lodAlpha_worldXZUndisplaced.x, i.invDeterminant_lodAlpha_worldXZUndisplaced.zw, n, i.shorelineFoam, col.xyz, whiteFoam );

					// Compute color of ocean - in-scattered light + refracted scene
					half2 uvScreen = i.vertex.xy / _ScreenParams.xy;
					OceanColour(view, n, uvScreen, i.vertex.z, col);

					// Fresnel / reflection
					half3 skyColor = texCUBE(_Skybox, reflect(-view, n));
					float fresnel = lerp(0., 1.0, pow(1.0 - dot(n, view), _FresnelPower));
					col = lerp(col, skyColor, fresnel);

					// Override final result with white foam - bubbles on surface
					col = lerp(col.xyz, _FoamWhiteColor, whiteFoam);

					// Fog
					UNITY_APPLY_FOG(i.fogCoord, col);
	
					#if defined( DEBUG_SHAPE_SAMPLE )
					col = mix(col.rgb, i.debugtint, 0.5);
					#endif

					return col;
					return (half4)i.shorelineFoam;
				}

				ENDCG
			}
		}
	}
}
