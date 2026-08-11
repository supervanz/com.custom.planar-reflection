using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Renders a planar reflection of the scene across a horizontal plane (the floor)
/// into a RenderTexture and exposes it globally as "_PlanarReflectionTexture".
/// Designed for URP (Unity 6 / SubmitRenderRequest API).
/// Attach to any GameObject; the reflection plane is defined by reflectionPlaneY + the
/// transform's position is ignored (plane is world-horizontal).
/// </summary>
[ExecuteAlways]
[DisallowMultipleComponent]
public class PlanarReflection : MonoBehaviour
{
    [Header("Reflection Plane")]
    [Tooltip("World-space Y height of the reflective plane (floor). The floor mesh sits at Y=0.")]
    public float reflectionPlaneY = 0f;

    [Tooltip("Small offset pushing the clip plane to avoid edge artifacts / leaking under the floor.")]
    public float clipPlaneOffset = 0.05f;

    [Header("Quality")]
    [Range(0.15f, 1f)]
    [Tooltip("Resolution of the reflection texture relative to the screen.")]
    public float resolutionMultiplier = 0.6f;

    [Tooltip("Layers that get reflected. Exclude the floor's own layer to avoid recursion artifacts.")]
    public LayerMask reflectLayers = -1;

    [Tooltip("Render the skybox into the reflection.")]
    public bool renderSkybox = true;

    [Range(0.1f, 4f)]
    [Tooltip("Multiplier applied to the reflection camera far clip relative to the source camera.")]
    public float farClipMultiplier = 1f;

    private Camera _reflectionCamera;
    private RenderTexture _reflectionTexture;
    private static readonly int PlanarReflectionTextureId = Shader.PropertyToID("_PlanarReflectionTexture");

    private bool _isRendering;
    private int _oldTexWidth = -1;
    private int _oldTexHeight = -1;

    private void OnEnable()
    {
        RenderPipelineManager.beginCameraRendering += OnBeginCameraRendering;
    }

    private void OnDisable()
    {
        RenderPipelineManager.beginCameraRendering -= OnBeginCameraRendering;
        Cleanup();
    }

    private void Cleanup()
    {
        if (_reflectionCamera != null)
        {
            _reflectionCamera.targetTexture = null;
            if (Application.isPlaying)
                Destroy(_reflectionCamera.gameObject);
            else
                DestroyImmediate(_reflectionCamera.gameObject);
            _reflectionCamera = null;
        }

        if (_reflectionTexture != null)
        {
            if (Application.isPlaying)
                Destroy(_reflectionTexture);
            else
                DestroyImmediate(_reflectionTexture);
            _reflectionTexture = null;
        }

        Shader.SetGlobalTexture(PlanarReflectionTextureId, Texture2D.blackTexture);
    }

    private void OnBeginCameraRendering(ScriptableRenderContext context, Camera camera)
    {
        // Never reflect the reflection / preview cameras: avoids recursion.
        if (_isRendering)
            return;
        if (camera.cameraType == CameraType.Reflection || camera.cameraType == CameraType.Preview)
            return;
        // Only reflect for game / scene-view cameras.
        if (camera.cameraType != CameraType.Game && camera.cameraType != CameraType.SceneView)
            return;
        // Planar reflection math here assumes a perspective camera. Orthographic cameras
        // (e.g. capture/thumbnail cameras) would produce invalid oblique projections.
        if (camera.orthographic)
            return;

        EnsureResources(camera);
        UpdateReflectionCamera(camera);

        _isRendering = true;

        // The reflection matrix has a negative determinant, which flips triangle
        // winding order. Without inverting culling, back faces get drawn (Cull Back
        // discards the real front faces), so meshes render with reversed normals and
        // appear as dark, front/back-flipped silhouettes in the reflection.
        bool previousInvertCulling = GL.invertCulling;
        GL.invertCulling = true;

        var request = new UniversalRenderPipeline.SingleCameraRequest
        {
            destination = _reflectionTexture
        };
        if (RenderPipeline.SupportsRenderRequest(_reflectionCamera, request))
        {
            RenderPipeline.SubmitRenderRequest(_reflectionCamera, request);
        }

        // Restore culling so the main camera render is unaffected.
        GL.invertCulling = previousInvertCulling;
        _isRendering = false;

        Shader.SetGlobalTexture(PlanarReflectionTextureId, _reflectionTexture);
    }

    private void EnsureResources(Camera sourceCamera)
    {
        int width = Mathf.Max(1, (int)(sourceCamera.pixelWidth * resolutionMultiplier));
        int height = Mathf.Max(1, (int)(sourceCamera.pixelHeight * resolutionMultiplier));

        if (_reflectionTexture == null || width != _oldTexWidth || height != _oldTexHeight)
        {
            if (_reflectionTexture != null)
            {
                if (Application.isPlaying) Destroy(_reflectionTexture);
                else DestroyImmediate(_reflectionTexture);
            }

            // ARGBHalf is used (instead of DefaultHDR) because it guarantees an alpha
            // channel. The floor shader relies on alpha == 0 to detect skybox-only
            // pixels and apply _SkyboxReflectionStrength to them.
            _reflectionTexture = new RenderTexture(width, height, 24, RenderTextureFormat.ARGBHalf)
            {
                name = "_PlanarReflectionTexture",
                useMipMap = false,
                autoGenerateMips = false
            };
            _reflectionTexture.Create();
            _oldTexWidth = width;
            _oldTexHeight = height;

            if (_reflectionCamera != null)
                _reflectionCamera.targetTexture = _reflectionTexture;
        }

        if (_reflectionCamera == null)
        {
            var go = new GameObject("PlanarReflectionCamera")
            {
                hideFlags = HideFlags.HideAndDontSave
            };
            _reflectionCamera = go.AddComponent<Camera>();
            _reflectionCamera.enabled = false;
            _reflectionCamera.cameraType = CameraType.Reflection;

            var data = go.AddComponent<UniversalAdditionalCameraData>();
            data.renderShadows = true;
            data.requiresColorOption = CameraOverrideOption.Off;
            data.requiresDepthOption = CameraOverrideOption.Off;

            _reflectionCamera.targetTexture = _reflectionTexture;
        }
    }

    private void UpdateReflectionCamera(Camera src)
    {
        // Copy core settings from the source camera.
        _reflectionCamera.CopyFrom(src);
        _reflectionCamera.enabled = false;
        _reflectionCamera.cameraType = CameraType.Reflection;
        _reflectionCamera.targetTexture = _reflectionTexture;
        _reflectionCamera.cullingMask = reflectLayers;
        // Always clear to transparent black instead of drawing the skybox into the
        // reflection texture. This leaves skybox-only pixels with alpha == 0, which the
        // floor shader detects to apply _SkyboxReflectionStrength via the environment
        // probe. (renderSkybox is intentionally no longer used for clear flags.)
        _reflectionCamera.clearFlags = CameraClearFlags.SolidColor;
        _reflectionCamera.backgroundColor = new Color(0f, 0f, 0f, 0f);
        _reflectionCamera.farClipPlane = src.farClipPlane * farClipMultiplier;

        var reflData = _reflectionCamera.GetUniversalAdditionalCameraData();
        if (reflData != null)
        {
            reflData.renderShadows = true;
            reflData.requiresColorTexture = false;
            reflData.requiresDepthTexture = false;
            reflData.renderType = CameraRenderType.Base;
        }

        Vector3 planePos = new Vector3(0f, reflectionPlaneY, 0f);
        Vector3 planeNormal = Vector3.up;

        // Mirror matrix across the plane.
        float d = -Vector3.Dot(planeNormal, planePos) - clipPlaneOffset;
        Vector4 reflectionPlane = new Vector4(planeNormal.x, planeNormal.y, planeNormal.z, d);

        Matrix4x4 reflection = Matrix4x4.identity;
        CalculateReflectionMatrix(ref reflection, reflectionPlane);

        Matrix4x4 worldToCamera = src.worldToCameraMatrix * reflection;
        _reflectionCamera.worldToCameraMatrix = worldToCamera;

        // Oblique near plane clipping so nothing below the floor is rendered.
        Vector4 clipPlane = CameraSpacePlane(worldToCamera, planePos, planeNormal, 1.0f);
        _reflectionCamera.projectionMatrix = src.CalculateObliqueMatrix(clipPlane);

        // Place camera transform at the mirrored position (used for some shader math/culling).
        Vector3 mirroredPos = reflection.MultiplyPoint(src.transform.position);
        _reflectionCamera.transform.position = mirroredPos;
        Vector3 forward = reflection.MultiplyVector(src.transform.forward);
        Vector3 up = reflection.MultiplyVector(src.transform.up);
        _reflectionCamera.transform.rotation = Quaternion.LookRotation(forward, up);
    }

    private static void CalculateReflectionMatrix(ref Matrix4x4 reflectionMat, Vector4 plane)
    {
        reflectionMat.m00 = (1F - 2F * plane[0] * plane[0]);
        reflectionMat.m01 = (-2F * plane[0] * plane[1]);
        reflectionMat.m02 = (-2F * plane[0] * plane[2]);
        reflectionMat.m03 = (-2F * plane[3] * plane[0]);

        reflectionMat.m10 = (-2F * plane[1] * plane[0]);
        reflectionMat.m11 = (1F - 2F * plane[1] * plane[1]);
        reflectionMat.m12 = (-2F * plane[1] * plane[2]);
        reflectionMat.m13 = (-2F * plane[3] * plane[1]);

        reflectionMat.m20 = (-2F * plane[2] * plane[0]);
        reflectionMat.m21 = (-2F * plane[2] * plane[1]);
        reflectionMat.m22 = (1F - 2F * plane[2] * plane[2]);
        reflectionMat.m23 = (-2F * plane[3] * plane[2]);

        reflectionMat.m30 = 0F;
        reflectionMat.m31 = 0F;
        reflectionMat.m32 = 0F;
        reflectionMat.m33 = 1F;
    }

    private Vector4 CameraSpacePlane(Matrix4x4 worldToCamera, Vector3 pos, Vector3 normal, float sideSign)
    {
        Vector3 offsetPos = pos + normal * clipPlaneOffset;
        Vector3 cpos = worldToCamera.MultiplyPoint(offsetPos);
        Vector3 cnormal = worldToCamera.MultiplyVector(normal).normalized * sideSign;
        return new Vector4(cnormal.x, cnormal.y, cnormal.z, -Vector3.Dot(cpos, cnormal));
    }
}
