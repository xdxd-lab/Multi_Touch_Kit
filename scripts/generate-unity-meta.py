#!/usr/bin/env python3
"""為 Unity 套件中缺少 .meta 的檔案與資料夾產生 .meta（已存在的不會改動，GUID 保持不變）。

以 git URL 安裝的套件是唯讀的，沒有 .meta 的檔案會被 Unity 忽略，所以新增檔案後一定要執行：
    python3 scripts/generate-unity-meta.py
"""
import pathlib
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Unity" / "com.xdxd-lab.multitouchkit"

FOLDER = """fileFormatVersion: 2
guid: {guid}
folderAsset: yes
DefaultImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""

SCRIPT = """fileFormatVersion: 2
guid: {guid}
MonoImporter:
  externalObjects: {{}}
  serializedVersion: 2
  defaultReferences: []
  executionOrder: 0
  icon: {{instanceID: 0}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""

ASMDEF = """fileFormatVersion: 2
guid: {guid}
AssemblyDefinitionImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""

PACKAGE = """fileFormatVersion: 2
guid: {guid}
PackageManifestImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""

TEXT = """fileFormatVersion: 2
guid: {guid}
TextScriptImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""

# 只啟用 macOS 編輯器與 macOS 執行檔
PLUGIN = """fileFormatVersion: 2
guid: {guid}
PluginImporter:
  externalObjects: {{}}
  serializedVersion: 2
  iconMap: {{}}
  executionOrder: {{}}
  defineConstraints: []
  isPreloaded: 0
  isOverridable: 1
  isExplicitlyReferenced: 0
  validateReferences: 1
  platformData:
  - first:
      : Any
    second:
      enabled: 0
      settings:
        Exclude Editor: 0
        Exclude Linux64: 1
        Exclude OSXUniversal: 0
        Exclude Win: 1
        Exclude Win64: 1
  - first:
      Any: 
    second:
      enabled: 0
      settings: {{}}
  - first:
      Editor: Editor
    second:
      enabled: 1
      settings:
        CPU: AnyCPU
        DefaultValueInitialized: true
        OS: OSX
  - first:
      Standalone: OSXUniversal
    second:
      enabled: 1
      settings:
        CPU: AnyCPU
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""


# 編輯器圖示：Editor GUI 貼圖、不產生 mipmap、保留透明（MultiTouchKitManager 元件圖示）
TEXTURE = """fileFormatVersion: 2
guid: {guid}
TextureImporter:
  internalIDToNameTable: []
  externalObjects: {{}}
  serializedVersion: 12
  mipmaps:
    enableMipMap: 0
    sRGBTexture: 1
  isReadable: 0
  textureFormat: 1
  maxTextureSize: 256
  textureSettings:
    serializedVersion: 2
    filterMode: 1
    aniso: 1
    mipBias: 0
    wrapU: 1
    wrapV: 1
    wrapW: 1
  alphaUsage: 1
  alphaIsTransparency: 1
  textureType: 2
  textureShape: 1
  spriteMode: 0
  platformSettings:
  - serializedVersion: 3
    buildTarget: DefaultTexturePlatform
    maxTextureSize: 256
    textureCompression: 0
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""


def template(path: pathlib.Path) -> str:
    if path.suffix == ".bundle":
        return PLUGIN
    if path.suffix == ".png":
        return TEXTURE
    if path.is_dir():
        return FOLDER
    if path.suffix == ".cs":
        return SCRIPT
    if path.suffix == ".asmdef":
        return ASMDEF
    if path.name == "package.json":
        return PACKAGE
    return TEXT


def visit(directory: pathlib.Path, created: list):
    for child in sorted(directory.iterdir()):
        name = child.name
        if name.startswith(".") or name.endswith(".meta") or name.endswith("~"):
            continue  # Unity 忽略隱藏檔與 ~ 結尾的資料夾（Samples~）
        meta = child.with_name(name + ".meta")
        if not meta.exists():
            meta.write_text(template(child).format(guid=uuid.uuid4().hex))
            created.append(meta.relative_to(ROOT))
        if child.is_dir() and child.suffix != ".bundle":
            visit(child, created)


created = []
visit(ROOT, created)
for path in created:
    print(f"已建立 {path}")
print(f"共建立 {len(created)} 個 .meta")
