#!/usr/bin/env python3
"""Deterministic Xcode project generation using only Python's standard library."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def ident(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

def obj(key, isa, **kwargs):
    key = ident(key)
    objects[key] = dict(isa=isa, **kwargs)
    return key

class Ref(str):
    pass

def ref(key):
    return Ref(ident(key))

def value(item):
    if isinstance(item, Ref): return str(item)
    if isinstance(item, str): return json.dumps(item)
    if isinstance(item, list): return "(\n" + "".join(value(v) + ",\n" for v in item) + ")"
    if isinstance(item, dict): return "{\n" + "".join(json.dumps(k) + " = " + value(v) + ";\n" for k, v in item.items()) + "}"
    return str(item)

sources = sorted(ROOT.glob("Sources/Albumer/**/*.swift"))
core = [p for p in sources if "Core" in p.parts]
model = [ROOT / "Sources/Albumer" / name for name in ["AppModel.swift", "ImageStore.swift", "FixtureSpotifyService.swift"]]
unit = sorted(ROOT.glob("Tests/AlbumerTests/*.swift"))
ui = sorted(ROOT.glob("Tests/AlbumerUITests/*.swift"))

allfiles = sources + unit + ui
for file in allfiles:
    path = str(file.relative_to(ROOT))
    obj(path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path, sourceTree="SOURCE_ROOT")
assets = "Sources/Albumer/Resources/Assets.xcassets"
fixtures = "Sources/Albumer/Resources/Fixtures"
legal = ["LICENSE", "PRIVACY.md", "TERMS.md", "THIRD_PARTY_NOTICES.md"]
for path in legal:
    obj(path, "PBXFileReference", lastKnownFileType="text", path=path, sourceTree="SOURCE_ROOT")
obj(assets, "PBXFileReference", lastKnownFileType="folder.assetcatalog", path=assets, sourceTree="SOURCE_ROOT")
obj(fixtures, "PBXFileReference", lastKnownFileType="folder", path=fixtures, sourceTree="SOURCE_ROOT")

targets = [("Albumer", sources, "application", "app"),
           ("AlbumerTests", core + model + unit, "bundle.unit-test", "xctest"),
           ("AlbumerUITests", ui, "bundle.ui-testing", "xctest")]

for name, files, kind, extension in targets:
    source_refs = []
    for file in files:
        path = str(file.relative_to(ROOT))
        source_refs.append(Ref(obj(name + path, "PBXBuildFile", fileRef=ref(path))))
    obj(name + "sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_refs, runOnlyForDeploymentPostprocessing=0)
    resource_refs = []
    if name == "Albumer":
        for path in [assets, fixtures] + legal: resource_refs.append(Ref(obj(name + path, "PBXBuildFile", fileRef=ref(path))))
    obj(name + "resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_refs, runOnlyForDeploymentPostprocessing=0)
    obj(name + "frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    obj(name + "product", "PBXFileReference", explicitFileType="wrapper.application" if extension == "app" else "wrapper.cfbundle", includeInIndex=0, path=f"{name}.{extension}", sourceTree="BUILT_PRODUCTS_DIR")
    configs = []
    for config in ["Debug", "Release"]:
        settings = dict(PRODUCT_NAME=name, PRODUCT_BUNDLE_IDENTIFIER="app.albumer" + ("" if name == "Albumer" else "." + name),
                        SWIFT_VERSION="6.0", MACOSX_DEPLOYMENT_TARGET="15.0", CODE_SIGN_IDENTITY="-", CODE_SIGN_STYLE="Manual",
                        GENERATE_INFOPLIST_FILE="YES", SDKROOT="macosx", SUPPORTED_PLATFORMS="macosx",
                        SWIFT_OPTIMIZATION_LEVEL="-Onone" if config == "Debug" else "-O", ENABLE_TESTABILITY="YES" if config == "Debug" else "NO",
                        SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG" if config == "Debug" else "",
                        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"])
        if name == "Albumer":
            settings.update(INFOPLIST_FILE="Sources/Albumer/Resources/Info.plist", GENERATE_INFOPLIST_FILE="NO",
                            ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", ENABLE_HARDENED_RUNTIME="YES", ENABLE_APP_SANDBOX="NO")
            if config == "Release":
                settings.update(SWIFT_SERIALIZE_DEBUGGING_OPTIONS="NO",
                                OTHER_SWIFT_FLAGS=["$(inherited)", "-debug-prefix-map", "$(SRCROOT)=/Albumer",
                                                   "-file-prefix-map", "$(SRCROOT)=/Albumer"],
                                COPY_PHASE_STRIP="YES", STRIP_INSTALLED_PRODUCT="YES")
        elif name == "AlbumerUITests": settings.update(TEST_TARGET_NAME="Albumer")
        configs.append(Ref(obj(name + config, "XCBuildConfiguration", name=config, buildSettings=settings)))
    obj(name + "configs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    dependencies = []
    if name == "AlbumerUITests":
        obj("uiProxy", "PBXContainerItemProxy", containerPortal=ref("project"), proxyType=1, remoteGlobalIDString=ref("Albumer"), remoteInfo="Albumer")
        dependencies.append(Ref(obj("uiDependency", "PBXTargetDependency", target=ref("Albumer"), targetProxy=ref("uiProxy"))))
    obj(name, "PBXNativeTarget", buildConfigurationList=ref(name + "configs"),
        buildPhases=[ref(name + "sources"), ref(name + "frameworks"), ref(name + "resources")], buildRules=[], dependencies=dependencies,
        name=name, productName=name, productReference=ref(name + "product"), productType="com.apple.product-type." + kind)

obj("products", "PBXGroup", children=[ref(n + "product") for n, *_ in targets], name="Products", sourceTree="<group>")
obj("root", "PBXGroup", children=[ref(str(f.relative_to(ROOT))) for f in allfiles] + [ref(assets), ref(fixtures)] + [ref(path) for path in legal] + [ref("products")], sourceTree="<group>")
configs = []
for config in ["Debug", "Release"]:
    configs.append(Ref(obj("project" + config, "XCBuildConfiguration", name=config,
                          buildSettings=dict(CLANG_ENABLE_MODULES="YES", SWIFT_VERSION="6.0", MACOSX_DEPLOYMENT_TARGET="15.0",
                                             SDKROOT="macosx", DEBUG_INFORMATION_FORMAT="dwarf"))))
obj("projectconfigs", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
obj("project", "PBXProject", attributes=dict(LastUpgradeCheck="1600", BuildIndependentTargetsInParallel="YES"),
    buildConfigurationList=ref("projectconfigs"), compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0,
    knownRegions=["en", "zh-Hans", "Base"], mainGroup=ref("root"), productRefGroup=ref("products"), projectDirPath="", projectRoot="",
    targets=[ref(n) for n, *_ in targets])

project = ROOT / "Albumer.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + value(dict(archiveVersion=1, classes={}, objectVersion=56,
    objects={Ref(k): v for k, v in objects.items()}, rootObject=ref("project"))) + "\n")

def buildable(name):
    ext = "app" if name == "Albumer" else "xctest"
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name)}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:Albumer.xcodeproj"/>'

scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
 <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable("Albumer")}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
 <Testables><TestableReference skipped="NO">{buildable("AlbumerTests")}</TestableReference><TestableReference skipped="NO">{buildable("AlbumerUITests")}</TestableReference></Testables>
 </TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("Albumer")}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("Albumer")}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
shared = project / "xcshareddata/xcschemes"
shared.mkdir(parents=True, exist_ok=True)
(shared / "Albumer.xcscheme").write_text(scheme)
print("Generated Albumer.xcodeproj")

