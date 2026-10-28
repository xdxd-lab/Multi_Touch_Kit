#!/bin/zsh
# 不開 Unity Editor 的 C# 檢查（使用 Unity 內建的 Roslyn 與 dotnet）：
#   1. 以 Unity 的參考組件編譯 Runtime（多組 define）與 Samples~，警告視為錯誤
#   2. 在 dotnet 上執行 Tests/UnityOffline（UDP 傳輸行為、JSON 解析器差分測試、零配置檢查）
# 用法：scripts/test-unity-offline.sh
#   UNITY_EDITOR=/Applications/Unity/Hub/Editor/<版本>/Unity.app   指定 Unity（預設取 Hub 中最新版）
#   UNITY_PROJECT=<Unity 專案>   從其 Library/ScriptAssemblies 取得 Unity.InputSystem.dll，以檢查 MTK_INPUT_SYSTEM
set -euo pipefail
cd "$(dirname "$0")/.."

UNITY=${UNITY_EDITOR:-$(ls -d /Applications/Unity/Hub/Editor/*/Unity.app 2>/dev/null | sort -V | tail -1)}
if [[ -z "$UNITY" || ! -d "$UNITY" ]]; then
    echo "找不到 Unity（請安裝或設定 UNITY_EDITOR）" >&2
    exit 2
fi
SCRIPTING=$UNITY/Contents/Resources/Scripting
DOTNET=$SCRIPTING/NetCoreRuntime/dotnet
CSC=($DOTNET $SCRIPTING/DotNetSdkRoslyn/csc.dll -nologo -noconfig -nostdlib)
PACKAGE=Unity/com.xdxd-lab.multitouchkit
OUT=.build/unity-offline
mkdir -p $OUT
echo "Unity：$UNITY"

# 1. 以 Unity 的參考組件編譯
API=$SCRIPTING/UnityReferenceAssemblies/unity-4.8-api
MODULES=$UNITY/Contents/Resources/Scripting/Managed/UnityEngine
UNITY_REFS=(-r:$API/mscorlib.dll -r:$API/System.dll -r:$API/System.Core.dll -r:$API/Facades/netstandard.dll)
for m in CoreModule IMGUIModule AudioModule InputLegacyModule TextRenderingModule; do
    UNITY_REFS+=(-r:$MODULES/UnityEngine.$m.dll)
done
INPUT_SYSTEM=""
for dir in ${UNITY_PROJECT:+$UNITY_PROJECT} ~/Projects/*(N/); do
    if [[ -f "$dir/Library/ScriptAssemblies/Unity.InputSystem.dll" ]]; then
        INPUT_SYSTEM=$dir/Library/ScriptAssemblies/Unity.InputSystem.dll
        break
    fi
done
DEFINES=("UNITY_EDITOR_OSX" "UNITY_STANDALONE_WIN")
if [[ -n "$INPUT_SYSTEM" ]]; then
    DEFINES=("UNITY_EDITOR_OSX;MTK_INPUT_SYSTEM" $DEFINES)
else
    echo "注意：找不到 Unity.InputSystem.dll，略過 MTK_INPUT_SYSTEM 的編譯（可設定 UNITY_PROJECT）"
fi
RUNTIME_SOURCES=(${(f)"$(find $PACKAGE/Runtime -name '*.cs')"})
# CS0649：JsonUtility／Inspector 填入的欄位
for define in $DEFINES; do
    $CSC -target:library -langversion:9 -warnaserror+ -nowarn:1701,1702,0649 -define:"$define" $UNITY_REFS \
        ${INPUT_SYSTEM:+-r:$INPUT_SYSTEM} -out:$OUT/Runtime.dll $RUNTIME_SOURCES
    echo "編譯 Runtime [$define]：OK"
done
$CSC -target:library -langversion:9 -warnaserror+ -nowarn:1701,1702 -define:UNITY_EDITOR_OSX $UNITY_REFS \
    -r:$OUT/Runtime.dll -out:$OUT/Samples.dll ${(f)"$(find $PACKAGE/Samples~ -name '*.cs')"}
echo "編譯 Samples~：OK"

# 2. 在 dotnet 上執行行為測試（以 UnityEngine 替身取代 Unity）
FRAMEWORK=$(ls -d $SCRIPTING/NetCoreRuntime/shared/Microsoft.NETCore.App/* | sort -V | tail -1)
NET_REFS=()
for f in $FRAMEWORK/System.*.dll $FRAMEWORK/Microsoft.Win32.Primitives.dll $FRAMEWORK/netstandard.dll $FRAMEWORK/mscorlib.dll; do
    NET_REFS+=(-r:$f)
done
$CSC -target:exe -langversion:latest -warnaserror+ -nowarn:1701,1702 $NET_REFS -out:$OUT/UnityOfflineTests.dll \
    Tests/UnityOffline/*.cs $PACKAGE/Runtime/MultiTouchTouch.cs $PACKAGE/Runtime/Transports/IMultiTouchTransport.cs \
    $PACKAGE/Runtime/Transports/UdpTransport.cs $PACKAGE/Runtime/Transports/TouchFrameJsonParser.cs
cat > $OUT/UnityOfflineTests.runtimeconfig.json <<JSON
{"runtimeOptions":{"tfm":"net6.0","framework":{"name":"Microsoft.NETCore.App","version":"${FRAMEWORK:t}"}}}
JSON
$DOTNET $OUT/UnityOfflineTests.dll Tests/UnityOffline/mtk-server-frames.jsonl
