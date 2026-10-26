#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(object_name, isa, **values):
    key = uid(object_name)
    objects[key] = {"isa": isa, **values}
    return key
def quote(value):
    if isinstance(value, list): return "(" + ", ".join(quote(v) for v in value) + ")"
    if isinstance(value, dict): return "{ " + " ".join(f"{quote(k)} = {quote(v)};" for k, v in value.items()) + " }"
    return json.dumps(str(value))

app_product = add("appProduct", "PBXFileReference", explicitFileType="wrapper.application", path="MacWindowHide.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("testProduct", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="MacWindowHideTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
groups = []
app_sources = []
test_sources = []
for folder, target_sources in [("MacWindowHide", app_sources), ("MacWindowHideTests", test_sources)]:
    refs = []
    for path in sorted((ROOT / folder).rglob("*")):
        if not path.is_file() or "Resources" in path.parts: continue
        ext = path.suffix
        types = {".swift": "sourcecode.swift", ".m": "sourcecode.c.objc", ".h": "sourcecode.c.h", ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements"}
        if ext not in types: continue
        relative = str(path.relative_to(ROOT))
        ref = add(relative, "PBXFileReference", lastKnownFileType=types[ext], path=relative, sourceTree="SOURCE_ROOT")
        refs.append(ref)
        if ext in [".swift", ".m"]: target_sources.append(add(relative + ":build", "PBXBuildFile", fileRef=ref))
    groups.append(add(folder + ":group", "PBXGroup", name=folder, children=refs, sourceTree="<group>"))

resource_builds = []
resource_refs = []
for name in ["AppIcon.icns"]:
    relative = "MacWindowHide/Resources/" + name
    ref = add(relative, "PBXFileReference", lastKnownFileType="image.icns", path=relative, sourceTree="SOURCE_ROOT")
    resource_refs.append(ref)
    resource_builds.append(add(relative + ":build", "PBXBuildFile", fileRef=ref))
groups.append(add("resourceGroup", "PBXGroup", name="Resources", children=resource_refs, sourceTree="<group>"))
notice_ref = add("noticeResource", "PBXFileReference", lastKnownFileType="text", path="THIRD_PARTY_NOTICES.md", sourceTree="SOURCE_ROOT")
resource_refs.append(notice_ref)
resource_builds.append(add("noticeResourceBuild", "PBXBuildFile", fileRef=notice_ref))
products = add("products", "PBXGroup", name="Products", children=[app_product, test_product], sourceTree="<group>")
main_group = add("mainGroup", "PBXGroup", children=groups + [products], sourceTree="<group>")
package = add("keyboardPackage", "XCLocalSwiftPackageReference", relativePath="Vendor/KeyboardShortcuts")
keyboard = add("keyboardProduct", "XCSwiftPackageProductDependency", package=package, productName="KeyboardShortcuts")
keyboard_build = add("keyboardBuild", "PBXBuildFile", productRef=keyboard)

def phase(name, isa, files): return add(name, isa, buildActionMask="2147483647", files=files, runOnlyForDeploymentPostprocessing="0")
app_phases = [phase("appSources", "PBXSourcesBuildPhase", app_sources), phase("appFrameworks", "PBXFrameworksBuildPhase", [keyboard_build]), phase("appResources", "PBXResourcesBuildPhase", resource_builds)]
test_phases = [phase("testSources", "PBXSourcesBuildPhase", test_sources), phase("testFrameworks", "PBXFrameworksBuildPhase", [])]

common = {
    "MACOSX_DEPLOYMENT_TARGET": "15.0", "SDKROOT": "macosx", "SWIFT_VERSION": "6.0",
    "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-", "DEVELOPMENT_TEAM": "",
    "SWIFT_STRICT_CONCURRENCY": "complete", "ARCHS": "$(ARCHS_STANDARD)", "GCC_C_LANGUAGE_STANDARD": "gnu17"
}
def configs(name, base):
    ids = []
    for mode in ["Debug", "Release"]:
        settings = dict(base)
        settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym", "ONLY_ACTIVE_ARCH": "YES" if mode == "Debug" else "NO"})
        if mode == "Debug": settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        ids.append(add(name + mode, "XCBuildConfiguration", name=mode, buildSettings=settings))
    return add(name + "Configs", "XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")
project_configs = configs("project", common)
app_configs = configs("app", {
    "PRODUCT_NAME": "MacWindowHide", "PRODUCT_BUNDLE_IDENTIFIER": "studio.macwindowhide.app",
    "INFOPLIST_FILE": "MacWindowHide/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "ENABLE_HARDENED_RUNTIME": "YES",
    "CODE_SIGN_ENTITLEMENTS": "MacWindowHide/MacWindowHide.entitlements", "ENABLE_APP_SANDBOX": "NO",
    "SWIFT_OBJC_BRIDGING_HEADER": "MacWindowHide/Platform/MacWindowHide-Bridging-Header.h",
    "HEADER_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/MacWindowHide/Platform"],
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "OTHER_LDFLAGS": ["$(inherited)", "-framework", "IOBluetooth", "-framework", "IOKit", "-framework", "CoreAudio", "-framework", "Carbon"],
    "COMBINE_HIDPI_IMAGES": "YES"
})
test_configs = configs("test", {
    "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "studio.macwindowhide.tests", "GENERATE_INFOPLIST_FILE": "YES",
    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/MacWindowHide.app/Contents/MacOS/MacWindowHide", "BUNDLE_LOADER": "$(TEST_HOST)",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
    "ENABLE_TESTABILITY": "YES"
})
objects[uid("appDebug")]["buildSettings"]["ENABLE_TESTABILITY"] = "YES"
app_target = add("appTarget", "PBXNativeTarget", name="MacWindowHide", productName="MacWindowHide", productReference=app_product,
    productType="com.apple.product-type.application", buildConfigurationList=app_configs, buildPhases=app_phases, buildRules=[], dependencies=[], packageProductDependencies=[keyboard])
proxy = add("testProxy", "PBXContainerItemProxy", containerPortal=uid("project"), proxyType="1", remoteGlobalIDString=app_target, remoteInfo="MacWindowHide")
dependency = add("testDependency", "PBXTargetDependency", target=app_target, targetProxy=proxy)
test_target = add("testTarget", "PBXNativeTarget", name="MacWindowHideTests", productName="MacWindowHideTests", productReference=test_product,
    productType="com.apple.product-type.bundle.unit-test", buildConfigurationList=test_configs, buildPhases=test_phases, buildRules=[], dependencies=[dependency])
project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2710", "TargetAttributes": {test_target: {"TestTargetID": app_target}}},
    buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings="0", knownRegions=["en", "Base"], mainGroup=main_group,
    productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, test_target], packageReferences=[package])
destination = ROOT / "MacWindowHide.xcodeproj"
destination.mkdir(exist_ok=True)
body = "\n".join(f"\t\t{k} = {quote(v)};" for k, v in objects.items())
(destination / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + body + "\n\t};\n\trootObject = " + project + ";\n}\n")
schemes = destination / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="MacWindowHide.app" BlueprintName="MacWindowHide" ReferencedContainer="container:MacWindowHide.xcodeproj"/>'
test_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="MacWindowHideTests.xctest" BlueprintName="MacWindowHideTests" ReferencedContainer="container:MacWindowHide.xcodeproj"/>'
(schemes / "MacWindowHide.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f"Generated project: {len(app_sources)} app sources, {len(test_sources)} test sources")
