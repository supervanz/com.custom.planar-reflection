Shader "Custom/FloorPlanarReflection"
{
    Properties
    {
        _BaseMap("Base Map", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)
        [Normal] _BumpMap("Normal Map", 2D) = "bump" {}
        _BumpScale("Normal Scale", Range(0,2)) = 1.0
        _ReflectionMask("Reflection Mask (R)", 2D) = "white" {}
        _Metallic("Metallic", Range(0,1)) = 0.0
        _Smoothness("Smoothness", Range(0,1)) = 0.5
        _ReflectionStrength("Reflection Strength", Range(0,1)) = 0.6
        _ReflectionTint("Reflection Tint", Color) = (1,1,1,1)
        _ReflectionFresnelPower("Reflection Fresnel Power", Range(0,8)) = 2.5
        _ReflectionBase("Reflection Base Amount", Range(0,1)) = 0.15
        _ReflectionBlur("Reflection Blur", Range(0,0.01)) = 0.0
        _ReflectionDistortion("Reflection Distortion (by normal)", Range(0,0.2)) = 0.05
        _SkyboxReflectionStrength("Skybox Reflection Strength", Range(0,10)) = 1.0

        [Header(Detail Inputs)]
        [Toggle(_DETAIL)] _DetailEnabled("Enable Detail Maps", Float) = 0
        _DetailMap("Detail Albedo x2 (overlay)", 2D) = "linearGrey" {}
        _DetailAlbedoMapScale("Detail Albedo Scale", Range(0,2)) = 1.0
        [Normal] _DetailNormalMap("Detail Normal", 2D) = "bump" {}
        _DetailNormalMapScale("Detail Normal Scale", Range(0,2)) = 1.0
        _DetailMask("Detail Mask (A)", 2D) = "white" {}
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" }
        LOD 300

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0

            // Material keywords
            #pragma shader_feature_local _NORMALMAP
            #pragma shader_feature_local _DETAIL

            // URP keywords
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _SCREEN_SPACE_OCCLUSION
            #pragma multi_compile _ _CLUSTER_LIGHT_LOOP
            #pragma multi_compile_fragment _ _LIGHT_LAYERS
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BLENDING
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BOX_PROJECTION
            #pragma multi_compile_fog

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                half4 _BaseColor;
                half _BumpScale;
                half _Metallic;
                half _Smoothness;
                half _ReflectionStrength;
                half4 _ReflectionTint;
                half _ReflectionFresnelPower;
                half _ReflectionBase;
                half _ReflectionBlur;
                half _ReflectionDistortion;
                half _SkyboxReflectionStrength;
                float4 _DetailMap_ST;
                half _DetailAlbedoMapScale;
                half _DetailNormalMapScale;
            CBUFFER_END

            TEXTURE2D(_BaseMap);          SAMPLER(sampler_BaseMap);
            TEXTURE2D(_BumpMap);          SAMPLER(sampler_BumpMap);
            TEXTURE2D(_ReflectionMask);   SAMPLER(sampler_ReflectionMask);
            TEXTURE2D(_PlanarReflectionTexture); SAMPLER(sampler_PlanarReflectionTexture);
            TEXTURE2D(_DetailMap);        SAMPLER(sampler_DetailMap);
            TEXTURE2D(_DetailNormalMap);  SAMPLER(sampler_DetailNormalMap);
            TEXTURE2D(_DetailMask);       SAMPLER(sampler_DetailMask);

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalWS   : TEXCOORD2;
                float4 screenPos  : TEXCOORD3;
                float4 tangentWS  : TEXCOORD4; // xyz = tangent, w = sign
                float2 detailUV   : TEXCOORD5;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT = (Varyings)0;
                VertexPositionInputs posInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs normInputs = GetVertexNormalInputs(IN.normalOS, IN.tangentOS);

                OUT.positionCS = posInputs.positionCS;
                OUT.positionWS = posInputs.positionWS;
                OUT.normalWS = normInputs.normalWS;
                real sign = IN.tangentOS.w * GetOddNegativeScale();
                OUT.tangentWS = float4(normInputs.tangentWS, sign);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                OUT.detailUV = TRANSFORM_TEX(IN.uv, _DetailMap);
                OUT.screenPos = ComputeScreenPos(posInputs.positionCS);
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half4 baseSample = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv);
                half3 albedo = baseSample.rgb * _BaseColor.rgb;

                float3 viewDirWS = normalize(GetWorldSpaceViewDir(IN.positionWS));

                // --- Normal mapping (tangent space -> world space) ---
                // Default _BumpMap is "bump" (flat normal) so this is a no-op until a
                // normal map is assigned in the material inspector.
                half3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, IN.uv), _BumpScale);

                // --- Detail maps (breaks up base map tiling) ---
                // Sampled at independent _DetailMap tiling so the secondary pattern
                // overlaps the base at a different frequency and hides repetition.
            #if defined(_DETAIL)
                half detailMask = SAMPLE_TEXTURE2D(_DetailMask, sampler_DetailMask, IN.uv).a;

                // Detail albedo as overlay (mul x2): grey (0.5) is neutral.
                half3 detailAlbedo = SAMPLE_TEXTURE2D(_DetailMap, sampler_DetailMap, IN.detailUV).rgb;
                half3 detailScaled = lerp(half3(1.0h, 1.0h, 1.0h), detailAlbedo * 2.0h, _DetailAlbedoMapScale * detailMask);
                albedo *= detailScaled;

                // Detail normal blended into the base tangent-space normal (whiteout blend).
                half3 detailNormalTS = UnpackNormalScale(
                    SAMPLE_TEXTURE2D(_DetailNormalMap, sampler_DetailNormalMap, IN.detailUV),
                    _DetailNormalMapScale * detailMask);
                normalTS = normalize(half3(normalTS.xy + detailNormalTS.xy, normalTS.z * detailNormalTS.z));
            #endif

                float3 tangentWS = normalize(IN.tangentWS.xyz);
                float3 geomNormalWS = normalize(IN.normalWS);
                float3 bitangentWS = IN.tangentWS.w * cross(geomNormalWS, tangentWS);
                float3x3 tangentToWorld = float3x3(tangentWS, bitangentWS, geomNormalWS);
                float3 normalWS = normalize(TransformTangentToWorld(normalTS, tangentToWorld));

                // --- Standard URP PBR lighting ---
                SurfaceData surfaceData = (SurfaceData)0;
                surfaceData.albedo = albedo;
                surfaceData.metallic = _Metallic;
                surfaceData.smoothness = _Smoothness;
                surfaceData.occlusion = 1.0h;
                surfaceData.alpha = 1.0h;
                surfaceData.normalTS = normalTS;

                InputData inputData = (InputData)0;
                inputData.positionWS = IN.positionWS;
                inputData.normalWS = normalWS;
                inputData.viewDirectionWS = viewDirWS;
            // The URP renderer has the Screen Space Shadows feature enabled, which uses the
            // _MAIN_LIGHT_SHADOWS_SCREEN keyword. In that path the shadow is sampled from the
            // screen-space shadow texture using ComputeScreenPos(), NOT the light-space coord.
            // Missing this case made the floor ignore the main directional light's shadows.
            #if defined(_MAIN_LIGHT_SHADOWS_SCREEN)
                inputData.shadowCoord = IN.screenPos;
            #elif defined(_MAIN_LIGHT_SHADOWS) || defined(_MAIN_LIGHT_SHADOWS_CASCADE)
                inputData.shadowCoord = TransformWorldToShadowCoord(IN.positionWS);
            #else
                inputData.shadowCoord = float4(0, 0, 0, 0);
            #endif
                inputData.bakedGI = SampleSH(normalWS);
                inputData.normalizedScreenSpaceUV = IN.screenPos.xy / max(IN.screenPos.w, 1e-4);
                inputData.shadowMask = half4(1, 1, 1, 1);
                inputData.fogCoord = ComputeFogFactor(IN.positionCS.z);

                // UniversalFragmentPBR applies screen-space AO internally to the lit color
                // (requires the DepthNormals pass below so the floor is present in the prepass).
                half4 color = UniversalFragmentPBR(inputData, surfaceData);

                // Fetch the screen-space AO factor so the reflection can be darkened too,
                // keeping ambient occlusion consistent across the mirrored image.
                half aoValue = 1.0h;
            #if defined(_SCREEN_SPACE_OCCLUSION)
                AmbientOcclusionFactor aoFactor = GetScreenSpaceAmbientOcclusion(inputData.normalizedScreenSpaceUV);
                aoValue = aoFactor.indirectAmbientOcclusion;
            #endif

                // --- Planar reflection blend ---
                float2 reflUV = IN.screenPos.xy / max(IN.screenPos.w, 1e-4);
                // Perturb the reflection by the tangent-space normal so surface bumps
                // ripple/warp the mirrored image.
                reflUV += normalTS.xy * _ReflectionDistortion;
                half4 reflectionSample = SAMPLE_TEXTURE2D(_PlanarReflectionTexture, sampler_PlanarReflectionTexture, saturate(reflUV));
                half3 reflection = reflectionSample.rgb;

                // Pixels the reflection camera left empty (alpha == 0) show no planar
                // geometry, so seed them with the environment probe to avoid black gaps.
                half skyMask = 1.0h - saturate(reflectionSample.a * 10.0h);
                float3 reflectDir = reflect(-viewDirWS, normalWS);
                half3 envReflection = GlossyEnvironmentReflection(reflectDir, 1.0h - _Smoothness, 1.0h);
                reflection = lerp(reflection, envReflection, skyMask);

                reflection *= aoValue; // AO darkens the reflection near occluded contact points

                // Per-texel reflection mask: polished plank faces reflect (mask ~1),
                // grooves / rough areas stay matte so baked & dynamic shadows remain visible (mask ~0).
                half reflMask = SAMPLE_TEXTURE2D(_ReflectionMask, sampler_ReflectionMask, IN.uv).r;

                half fresnel = pow(1.0h - saturate(dot(normalWS, viewDirWS)), _ReflectionFresnelPower);
                half reflAmount = saturate(_ReflectionStrength * (_ReflectionBase + (1.0h - _ReflectionBase) * fresnel));
                reflAmount *= _Smoothness; // glossier floor reflects more
                reflAmount *= reflMask;    // mask gates the planar reflection

                color.rgb = lerp(color.rgb, reflection * _ReflectionTint.rgb, reflAmount);

                // --- Additive environment (IBL) sky reflection ---
                // Select ONLY the pixels where the sky reaches the floor, using the
                // reflection texture alpha as a path mask:
                //   a ~ 0.0  : fully empty area (open sky)          -> included (boost 1)
                //   a ~ 0.56 : semi-transparent glass (window/skylight) -> included (sky reaches floor through it)
                //   a ~ 1.0  : opaque objects (walls/statues/bases) -> excluded (boost 0)
                // GlassMat alpha is ~0.56 and opaque geometry is 1.0, so smoothstep(0.6,0.9)
                // gives glass the full boost while keeping opaque reflections untouched.
                half skyBoost = 1.0h - smoothstep(0.6h, 0.9h, reflectionSample.a);

                half envAmount = _SkyboxReflectionStrength * (_ReflectionBase + (1.0h - _ReflectionBase) * fresnel);
                color.rgb += envReflection * _ReflectionTint.rgb * envAmount * aoValue * skyBoost * reflMask;

                color.rgb = MixFog(color.rgb, inputData.fogCoord);
                return half4(color.rgb, 1.0h);
            }
            ENDHLSL
        }

        // Shadow casting
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode"="ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma vertex ShadowPassVertex
            #pragma fragment ShadowPassFragment
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            float3 _LightDirection;
            float3 _LightPosition;

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                half4 _BaseColor;
                half _BumpScale;
                half _Metallic;
                half _Smoothness;
                half _ReflectionStrength;
                half4 _ReflectionTint;
                half _ReflectionFresnelPower;
                half _ReflectionBase;
                half _ReflectionBlur;
                half _ReflectionDistortion;
                half _SkyboxReflectionStrength;
                float4 _DetailMap_ST;
                half _DetailAlbedoMapScale;
                half _DetailNormalMapScale;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            float4 GetShadowPositionHClip(Attributes input)
            {
                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);

            #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                float3 lightDirectionWS = normalize(_LightPosition - positionWS);
            #else
                float3 lightDirectionWS = _LightDirection;
            #endif

                float4 positionCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, lightDirectionWS));

            #if UNITY_REVERSED_Z
                positionCS.z = min(positionCS.z, UNITY_NEAR_CLIP_VALUE);
            #else
                positionCS.z = max(positionCS.z, UNITY_NEAR_CLIP_VALUE);
            #endif
                return positionCS;
            }

            Varyings ShadowPassVertex(Attributes input)
            {
                Varyings output;
                output.positionCS = GetShadowPositionHClip(input);
                return output;
            }

            half4 ShadowPassFragment(Varyings input) : SV_TARGET
            {
                return 0;
            }
            ENDHLSL
        }

        // Depth only
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode"="DepthOnly" }

            ZWrite On
            ColorMask R
            Cull Back

            HLSLPROGRAM
            #pragma vertex DepthOnlyVertex
            #pragma fragment DepthOnlyFragment

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                half4 _BaseColor;
                half _BumpScale;
                half _Metallic;
                half _Smoothness;
                half _ReflectionStrength;
                half4 _ReflectionTint;
                half _ReflectionFresnelPower;
                half _ReflectionBase;
                half _ReflectionBlur;
                half _ReflectionDistortion;
                half _SkyboxReflectionStrength;
                float4 _DetailMap_ST;
                half _DetailAlbedoMapScale;
                half _DetailNormalMapScale;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            Varyings DepthOnlyVertex(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                return output;
            }

            half4 DepthOnlyFragment(Varyings input) : SV_TARGET
            {
                return 0;
            }
            ENDHLSL
        }

        // Depth + Normals prepass.
        // Required so this surface is written into the camera normals/depth buffers used by
        // URP Screen Space Ambient Occlusion when its Source is set to "Depth Normals".
        // Without this pass the floor is missing from the prepass and receives no AO.
        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode"="DepthNormals" }

            ZWrite On
            Cull Back

            HLSLPROGRAM
            #pragma vertex DepthNormalsVertex
            #pragma fragment DepthNormalsFragment

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                half4 _BaseColor;
                half _BumpScale;
                half _Metallic;
                half _Smoothness;
                half _ReflectionStrength;
                half4 _ReflectionTint;
                half _ReflectionFresnelPower;
                half _ReflectionBase;
                half _ReflectionBlur;
                half _ReflectionDistortion;
                half _SkyboxReflectionStrength;
                float4 _DetailMap_ST;
                half _DetailAlbedoMapScale;
                half _DetailNormalMapScale;
            CBUFFER_END

            TEXTURE2D(_BumpMap);          SAMPLER(sampler_BumpMap);

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float3 normalWS   : TEXCOORD1;
                float4 tangentWS  : TEXCOORD2; // xyz = tangent, w = sign
            };

            Varyings DepthNormalsVertex(Attributes input)
            {
                Varyings output = (Varyings)0;
                VertexPositionInputs posInputs = GetVertexPositionInputs(input.positionOS.xyz);
                VertexNormalInputs normInputs = GetVertexNormalInputs(input.normalOS, input.tangentOS);

                output.positionCS = posInputs.positionCS;
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                output.normalWS = normInputs.normalWS;
                real sign = input.tangentOS.w * GetOddNegativeScale();
                output.tangentWS = float4(normInputs.tangentWS, sign);
                return output;
            }

            half4 DepthNormalsFragment(Varyings input) : SV_Target
            {
                // Apply the normal map so AO uses the perturbed surface normals.
                half3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv), _BumpScale);
                float3 tangentWS = normalize(input.tangentWS.xyz);
                float3 geomNormalWS = normalize(input.normalWS);
                float3 bitangentWS = input.tangentWS.w * cross(geomNormalWS, tangentWS);
                float3x3 tangentToWorld = float3x3(tangentWS, bitangentWS, geomNormalWS);
                float3 normalWS = normalize(TransformTangentToWorld(normalTS, tangentToWorld));

                return half4(NormalizeNormalPerPixel(normalWS), 0.0);
            }
            ENDHLSL
        }
    }

    FallBack "Universal Render Pipeline/Lit"
}
