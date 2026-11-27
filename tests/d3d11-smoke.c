/* Minimal D3D11 smoke test for the graphics backends (see scripts/smoke-test-graphics.sh).
 *
 *   d3d11-smoke.exe dxmt|dxvk|wined3d
 *
 * Exit codes: 0 = device created and a render-target clear was submitted,
 *             2 = the backend's DLLs did not load (a packaging/install bug),
 *             3 = DLLs loaded but no D3D11 device could be created (e.g. the GPU in a
 *                 virtual machine lacks a required Metal/Vulkan feature).
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d11-smoke64.exe d3d11-smoke.c   (no import libs needed)
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <d3d11.h>

static void print_module(const char *name)
{
    char path[MAX_PATH];
    HMODULE mod = GetModuleHandleA(name);
    if (mod && GetModuleFileNameA(mod, path, sizeof(path)))
        printf("  %-14s %s\n", name, path);
    else
        printf("  %-14s (not loaded)\n", name);
}

int main(int argc, char **argv)
{
    const char *backend = argc > 1 ? argv[1] : "wined3d";
    static const D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
    };
    PFN_D3D11_CREATE_DEVICE create;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HMODULE d3d11;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("d3d11-smoke (%d-bit), backend=%s\n", (int)(sizeof(void *) * 8), backend);

    d3d11 = LoadLibraryA("d3d11.dll");
    if (!d3d11) {
        printf("FAIL: LoadLibrary(d3d11.dll) error %lu\n", GetLastError());
        return 2;
    }
    if (!strcmp(backend, "dxmt") && !GetModuleHandleA("winemetal.dll")) {
        /* DXMT's d3d11/dxgi import winemetal.dll; winemetal's DllMain fails unless its
         * unixlib (winemetal.so) loads, so this proves both sides are installed. */
        print_module("d3d11.dll");
        printf("FAIL: winemetal.dll not loaded, so d3d11.dll is not DXMT's\n");
        return 2;
    }
    create = (PFN_D3D11_CREATE_DEVICE)(void *)GetProcAddress(d3d11, "D3D11CreateDevice");
    if (!create) {
        printf("FAIL: D3D11CreateDevice not exported\n");
        return 2;
    }

    hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, ARRAYSIZE(levels),
                D3D11_SDK_VERSION, &device, &level, &context);
    printf("modules:\n");
    print_module("d3d11.dll");
    print_module("dxgi.dll");
    print_module("winemetal.dll");
    print_module("winevulkan.dll");
    if (FAILED(hr)) {
        printf("FAIL: D3D11CreateDevice hr=0x%08lx\n", (unsigned long)hr);
        return 3;
    }
    printf("device created, feature level 0x%x\n", (unsigned)level);

    {
        D3D11_TEXTURE2D_DESC desc = {0};
        ID3D11Texture2D *tex = NULL;
        ID3D11RenderTargetView *rtv = NULL;
        static const float color[4] = {0.0f, 0.5f, 1.0f, 1.0f};

        desc.Width = desc.Height = 64;
        desc.MipLevels = desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET;
        hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &tex);
        if (FAILED(hr)) { printf("FAIL: CreateTexture2D hr=0x%08lx\n", (unsigned long)hr); return 3; }
        hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)tex, NULL, &rtv);
        if (FAILED(hr)) { printf("FAIL: CreateRenderTargetView hr=0x%08lx\n", (unsigned long)hr); return 3; }
        ID3D11DeviceContext_ClearRenderTargetView(context, rtv, color);
        ID3D11DeviceContext_Flush(context);
        ID3D11RenderTargetView_Release(rtv);
        ID3D11Texture2D_Release(tex);
    }

    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    printf("OK\n");
    return 0;
}
