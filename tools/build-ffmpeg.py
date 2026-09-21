#!/usr/bin/env python3
"""Build Breezy's private, dynamic FFmpegBridge using only Python and Xcode tools."""
# SPDX-License-Identifier: LGPL-2.1-or-later

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Vendor" / "FFmpegBridge"
WORK = ROOT / "artifacts" / "FFmpegBuild"
FRAMEWORK_NAME = "FFmpegBridge.framework"
INSTALL_NAME = "@rpath/FFmpegBridge.framework/FFmpegBridge"
SLICE_SPECS = {
    "iphoneos-arm64": ("iphoneos", "arm64", "aarch64", "IOS"),
    "iphonesimulator-arm64": ("iphonesimulator", "arm64", "aarch64", "IOSSIMULATOR"),
    "iphonesimulator-x86_64": ("iphonesimulator", "x86_64", "x86_64", "IOSSIMULATOR"),
}
COMPONENTS = {
    "DEMUXER": {"MATROSKA_DEMUXER"},
    "MUXER": {"MOV_MUXER", "MP4_MUXER"},
    "PARSER": {"AC3_PARSER", "OPUS_PARSER"},
    "PROTOCOL": {"FILE_PROTOCOL"},
    "ENCODER": set(), "DECODER": set(), "BSF": set(), "FILTER": set(),
    "HWACCEL": set(), "INDEV": set(), "OUTDEV": set(),
}
EXPORTED_SYMBOLS = {"_gb_ffmpeg_version", "_gb_remux_opus"}
LIBRARIES = ("avformat", "avcodec", "avutil")


class BuildError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise BuildError(message)


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    require(not path.is_symlink() and not temporary.is_symlink(), f"Refusing symlink: {path.name}")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    temporary.replace(path)


def read_json(path):
    return json.loads(path.read_text())


def files_under(directory):
    files = []
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory)
        if ".git" in relative.parts:
            continue
        require(not path.is_symlink(), f"Source or output contains a symlink: {relative}")
        require(path.is_file() or path.is_dir(), f"Unexpected file type: {relative}")
        if path.is_file():
            files.append(path)
    return files


def tree_manifest(directory):
    return {
        path.relative_to(directory).as_posix(): {
            "sha256": digest(path),
            "executable": bool(path.stat().st_mode & stat.S_IXUSR),
        }
        for path in files_under(directory)
    }


def owned_directory(path):
    require(path.is_relative_to(ROOT), "Output must stay within the app repository")
    relative = path.relative_to(ROOT)
    current = ROOT
    for part in relative.parts:
        current /= part
        require(not current.is_symlink(), f"Refusing symlink directory: {current}")
        current.mkdir(exist_ok=True)
        require(current.is_dir(), f"Not a directory: {current}")
    return path


def tool_environment():
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ["HOME"],
        "LC_ALL": "C", "LANG": "C", "TZ": "UTC",
        "TMPDIR": str(owned_directory(WORK / "tmp")),
    }
    if "DEVELOPER_DIR" in os.environ:
        environment["DEVELOPER_DIR"] = os.environ["DEVELOPER_DIR"]
    return environment


def run(command, *, cwd=ROOT, env=None, log=None):
    command = [str(argument) for argument in command]
    if env is None:
        env = tool_environment()
    if log:
        with log.open("a") as stream:
            stream.write("$ " + shlex.join(command) + "\n")
            stream.flush()
            result = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        require(result.returncode == 0, f"Command failed ({result.returncode}); see {log.relative_to(ROOT)}")
        return ""
    result = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0,
            f"Command failed ({result.returncode}): {shlex.join(command)}\n{result.stderr.strip()}")
    return result.stdout.strip()


@contextlib.contextmanager
def build_lock():
    fd = os.open(WORK / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise BuildError("Another FFmpegBridge build owns artifacts/FFmpegBuild/.lock") from error
        yield
    finally:
        os.close(fd)


class HTTPSOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        require(urllib.parse.urlparse(new_url).scheme == "https", "Source redirect must use HTTPS")
        return super().redirect_request(request, response, code, message, headers, new_url)


def source_archive(pins):
    archive = WORK / f"ffmpeg-{pins['version']}.tar.xz"
    require(not archive.is_symlink(), "Source archive must not be a symlink")
    if not archive.exists():
        require(urllib.parse.urlparse(pins["url"]).scheme == "https", "Source URL must use HTTPS")
        fd, name = tempfile.mkstemp(prefix="download-", suffix=".part", dir=WORK)
        temporary = Path(name)
        try:
            request = urllib.request.Request(pins["url"], headers={"User-Agent": "FFmpegBridge-build/1"})
            opener = urllib.request.build_opener(HTTPSOnlyRedirect())
            with os.fdopen(fd, "wb") as target, opener.open(request, timeout=60) as response:
                count = 0
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    count += len(block)
                    require(count <= 128 * 1024 * 1024, "Source download exceeds 128 MiB")
                    target.write(block)
            require(digest(temporary) == pins["sha256"], "Downloaded source SHA-256 does not match Source.json")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    require(digest(archive) == pins["sha256"],
            "Cached source SHA-256 mismatch; preserve/investigate the archive before replacing it")
    return archive


def extract_verified(archive, destination, pins):
    # No archive metadata or payload is extracted until the complete compressed file is verified.
    require(digest(archive) == pins["sha256"], "Source SHA-256 mismatch before extraction")
    with tarfile.open(archive, "r:xz") as source:
        members = source.getmembers()
        require(len(members) < 50000, "Source archive has too many entries")
        total = 0
        names = set()
        for member in members:
            name = PurePosixPath(member.name)
            require(not name.is_absolute() and ".." not in name.parts and name.parts and
                    name.parts[0] == f"ffmpeg-{pins['version']}" and
                    (member.isfile() or member.isdir()), "Unsafe source archive member")
            require(member.name not in names, "Duplicate source archive member")
            names.add(member.name)
            total += member.size
            require(total <= 512 * 1024 * 1024, "Expanded source exceeds 512 MiB")
            member.mode &= 0o755
        source.extractall(destination, members=members)


def apply_required_patches(source, patches, log):
    for patch in patches:
        command = ["/usr/bin/patch", "-p1", "-f", "-F0", "-i", str(patch)]
        forward = subprocess.run([*command, "-C", "-N"], cwd=source, env=tool_environment(),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if forward.returncode == 0:
            run([*command, "-N"], cwd=source, log=log)
            continue
        reverse = subprocess.run([*command, "-C", "-R"], cwd=source, env=tool_environment(),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        require(reverse.returncode == 0,
                f"Source conflicts with required patch {patch.name}; reconcile the source and patch before rebuilding")


def prepare_source(pins, override):
    patches = sorted((PACKAGE / "Patches").glob("*.patch"))
    patch_hashes = {patch.name: digest(patch) for patch in patches}
    original_tree = tree_manifest(override) if override else None
    identity = {"upstream": pins, "patches": patch_hashes, "patch_policy": 2,
                "override": fingerprint(original_tree) if override else None}
    source_parent = owned_directory(WORK / "source")
    destination = source_parent / (f"ffmpeg-{pins['version']}-" + fingerprint(identity)[:20])
    stamp = destination.with_name(destination.name + ".json")
    if destination.exists():
        require(stamp.is_file(), "Incomplete source cache; move it aside before retrying")
        recorded = read_json(stamp)
        require(recorded["identity"] == identity and
                recorded["tree_sha256"] == fingerprint(tree_manifest(destination)),
                "Prepared source changed. Use --source-dir to explicitly rebuild modified source")
        return destination, recorded

    staging = Path(tempfile.mkdtemp(prefix="extract-", dir=source_parent))
    try:
        source = staging / f"ffmpeg-{pins['version']}"
        if override:
            shutil.copytree(override, source, ignore=shutil.ignore_patterns(".git"))
            require(tree_manifest(source) == original_tree, "Modified source changed while being copied")
        else:
            extract_verified(source_archive(pins), staging, pins)
        require((source / "RELEASE").read_text().strip() == pins["version"], "Unexpected source release")
        require(not (source / "config.h").exists(), "Use a clean source tree, not an in-tree FFmpeg build")
        require(digest(source / "COPYING.LGPLv2.1") == digest(PACKAGE / "COPYING.LGPLv2.1"),
                "Packaged LGPL text differs from the corresponding upstream source")
        apply_required_patches(source, patches, WORK / "source-patch.log")
        recorded = {
            "identity": identity,
            "tree_sha256": fingerprint(tree_manifest(source)),
            "modified_source": bool(override),
            "patches": patch_hashes,
        }
        source.rename(destination)
        write_json(stamp, recorded)
        return destination, recorded
    finally:
        shutil.rmtree(staging)


def compiler_script(name, minimum_ios):
    sdk, arch, _, _ = SLICE_SPECS[name]
    target = f"{arch}-apple-ios{minimum_ios}" + ("-simulator" if sdk == "iphonesimulator" else "")
    return f'''#!/bin/sh
set -eu
exec /usr/bin/xcrun --sdk {sdk} clang -target {target} \\
  -isysroot "${{SDKROOT:?}}" \\
  -ffile-prefix-map="${{GB_PROJECT_ROOT:?}}"=/breezy \\
  -ffile-prefix-map="${{GB_SOURCE_ROOT:?}}"=/ffmpeg-src \\
  -ffile-prefix-map="${{GB_SOURCE_REL:?}}"=/ffmpeg-src \\
  -ffile-prefix-map="${{GB_BUILD_ROOT:?}}"=/ffmpeg-build/{name} \\
  -fdebug-compilation-dir=/ffmpeg-build/{name} -Werror=date-time "$@"
'''


def configure_arguments(name):
    _, _, configure_arch, _ = SLICE_SPECS[name]
    return [
        "--prefix=../install", "--target-os=darwin", f"--arch={configure_arch}", "--cpu=generic",
        "--enable-cross-compile", "--cc=./apple-clang", "--cxx=./apple-clang", "--as=./apple-clang",
        "--ld=./apple-clang", "--ar=/usr/bin/ar", "--ranlib=/usr/bin/ranlib", "--nm=/usr/bin/nm",
        "--host-cc=/usr/bin/env -u SDKROOT /usr/bin/xcrun --sdk macosx clang", "--pkg-config=/usr/bin/false",
        "--disable-gpl", "--disable-nonfree", "--disable-version3", "--disable-autodetect",
        "--disable-network", "--disable-programs", "--disable-doc", "--disable-everything",
        "--disable-avdevice", "--disable-avfilter", "--disable-swscale", "--disable-swresample",
        "--disable-encoders", "--disable-decoders", "--disable-bsfs", "--disable-filters",
        "--disable-hwaccels", "--disable-asm", "--disable-x86asm", "--disable-inline-asm",
        "--disable-shared", "--enable-static", "--enable-pic", "--enable-small",
        "--disable-debug", "--disable-stripping", "--disable-symver", "--disable-version-tracking",
        "--enable-pthreads", "--enable-avutil", "--enable-avcodec", "--enable-avformat",
        "--enable-demuxer=matroska", "--enable-muxer=mp4", "--enable-parser=opus", "--enable-protocol=file",
        "--extra-cflags=-Oz -fPIC -fvisibility=hidden -fno-ident",
        "--extra-ldflags=-Wl,-no_uuid",
    ]


def toolchain(sdk, minimum_ios):
    sdk_path = Path(run(["/usr/bin/xcrun", "--sdk", sdk, "--show-sdk-path"]))
    sdk_version = run(["/usr/bin/xcrun", "--sdk", sdk, "--show-sdk-version"])
    require(tuple(map(int, sdk_version.split("."))) >= tuple(map(int, minimum_ios.split("."))),
            f"{sdk} SDK is older than iOS {minimum_ios}")
    information = {
        "xcode": run(["/usr/bin/xcodebuild", "-version"]).splitlines(),
        "clang": run(["/usr/bin/xcrun", "--sdk", sdk, "clang", "--version"]).splitlines()[0],
        "sdk": sdk,
        "sdk_version": sdk_version,
        "sdk_build": run(["/usr/bin/xcrun", "--sdk", sdk, "--show-sdk-build-version"]),
        "sdk_settings_sha256": digest(sdk_path / "SDKSettings.json"),
    }
    return sdk_path, information


def build_environment(build, source, sdk_path, pins):
    environment = tool_environment()
    environment.update({
        "SOURCE_DATE_EPOCH": str(pins["source_date_epoch"]), "ZERO_AR_DATE": "1",
        "SDKROOT": str(sdk_path), "TMPDIR": str(owned_directory(build / "tmp")),
        "GB_PROJECT_ROOT": str(ROOT), "GB_SOURCE_ROOT": str(source),
        "GB_SOURCE_REL": os.path.relpath(source, build), "GB_BUILD_ROOT": str(build),
    })
    return environment


def audit_configuration(build):
    text = (build / "config.h").read_text() + (build / "config_components.h").read_text()
    flags = {name: int(value) for name, value in re.findall(r"^#define CONFIG_(\w+) ([01])$", text, re.MULTILINE)}
    for suffix, allowed in COMPONENTS.items():
        enabled = {name for name, value in flags.items() if name.endswith("_" + suffix) and value}
        require(enabled == allowed, f"Unexpected {suffix} configuration: {sorted(enabled)}")
    for name in ("GPL", "NONFREE", "VERSION3", "GPLV3", "LGPLV3", "NETWORK", "AUTODETECT",
                 "AVDEVICE", "AVFILTER", "SWSCALE", "SWRESAMPLE", "FFMPEG", "FFPLAY", "FFPROBE", "IAMFENC"):
        require(flags.get(name, 0) == 0, f"Forbidden FFmpeg feature: {name}")
    for name in ("AVFORMAT", "AVCODEC", "AVUTIL", "STATIC", "PIC"):
        require(flags.get(name) == 1, f"Missing FFmpeg feature: {name}")
    require(flags.get("SHARED", 0) == 0, "FFmpeg must be static inside the dynamic bridge")
    require('"LGPL version 2.1 or later"' in text, "FFmpeg's configured license is not LGPL-2.1-or-later")
    return sorted(name for name, value in flags.items() if value)


def cache_files_match(directory, record):
    return all((directory / name).is_file() and not (directory / name).is_symlink() and
               digest(directory / name) == value for name, value in record.items())


def build_libraries(name, source, source_record, pins, args):
    sdk_path, tools = toolchain(SLICE_SPECS[name][0], pins["minimum_ios"])
    wrapper = compiler_script(name, pins["minimum_ios"])
    arguments = configure_arguments(name)
    recipe = {
        "build_script_sha256": digest(Path(__file__)),
        "source_tree_sha256": source_record["tree_sha256"], "toolchain": tools,
        "configure": arguments, "compiler_driver": wrapper,
        "revision": pins["version"], "source_date_epoch": pins["source_date_epoch"],
        "make_targets": [f"lib{library}/lib{library}.a" for library in LIBRARIES],
    }
    recipe_hash = fingerprint(recipe)
    slice_root = owned_directory(WORK / "slices" / name / recipe_hash[:20])
    build = owned_directory(slice_root / "build")
    install = owned_directory(slice_root / "install")
    environment = build_environment(build, source, sdk_path, pins)
    driver = build / "apple-clang"
    stamp = slice_root / "libraries.json"
    if stamp.exists():
        recorded = read_json(stamp)
        if (recorded["recipe"] == recipe and cache_files_match(slice_root, recorded["files"]) and
                driver.is_file() and not driver.is_symlink() and driver.read_text() == wrapper):
            audit_configuration(build)
            print(f"Libraries cached: {name}")
            return slice_root, environment, recorded
    require(args.component in ("all", "libraries"),
            f"Libraries missing or stale for {name}; run --component libraries --slice {name}")
    log = slice_root / "libraries.log"
    require(not driver.is_symlink(), "Refusing symlinked compiler driver")
    driver.write_text(wrapper)
    driver.chmod(0o755)
    configured = build / "configured.json"
    if not configured.exists():
        print(f"Configuring: {name}")
        run(["/bin/sh", os.path.relpath(source / "configure", build), *arguments],
            cwd=build, env=environment, log=log)
        enabled = audit_configuration(build)
        write_json(configured, {"recipe_sha256": recipe_hash, "enabled": enabled})
    require(read_json(configured)["recipe_sha256"] == recipe_hash, "Mismatched configuration cache")
    enabled = audit_configuration(build)
    print(f"Building libraries: {name} (log: {log.relative_to(ROOT)})")
    make = ["/usr/bin/make", f"-j{args.jobs}", f"REVISION={pins['version']}"]
    run([*make, *recipe["make_targets"]], cwd=build, env=environment, log=log)
    run([*make, "install-libs", "install-headers"], cwd=build, env=environment, log=log)
    require(f'#define FFMPEG_VERSION "{pins["version"]}"' in (build / "libavutil" / "ffversion.h").read_text(),
            "Built FFmpeg version does not match the source pin")
    expected_arch = SLICE_SPECS[name][1]
    for library in LIBRARIES:
        archive = install / "lib" / f"lib{library}.a"
        require(run(["/usr/bin/xcrun", "lipo", "-archs", archive]).split() == [expected_arch],
                f"Wrong architecture in {archive.name}")
    recorded = {
        "recipe": recipe, "recipe_sha256": recipe_hash, "enabled_features": enabled,
        "files": {
            path.relative_to(slice_root).as_posix(): digest(path)
            for path in [build / "config.h", build / "config_components.h", *files_under(install)]
        },
    }
    write_json(stamp, recorded)
    return slice_root, environment, recorded


def wrapper_sources():
    return [*sorted((PACKAGE / "Sources").glob("*.c")), *sorted((PACKAGE / "include").glob("*.h")),
            PACKAGE / "Framework.modulemap", PACKAGE / "exports.txt", PACKAGE / "COPYING.LGPLv2.1",
            PACKAGE / "LICENSE.md", PACKAGE / "NOTICE.md"]


def framework_plist(pins, simulator):
    return {
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": "FFmpegBridge",
        "CFBundleIdentifier": "com.agraabhi.ganabajana.ffmpegbridge",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "FFmpegBridge",
        "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": pins["version"],
        "CFBundleVersion": pins["version"], "MinimumOSVersion": pins["minimum_ios"],
        "CFBundleSupportedPlatforms": ["iPhoneSimulator" if simulator else "iPhoneOS"],
    }


def write_framework_contents(framework, pins, simulator):
    (framework / "Headers").mkdir(parents=True)
    (framework / "Modules").mkdir()
    shutil.copyfile(PACKAGE / "include" / "FFmpegBridge.h", framework / "Headers" / "FFmpegBridge.h")
    shutil.copyfile(PACKAGE / "Framework.modulemap", framework / "Modules" / "module.modulemap")
    for name in ("COPYING.LGPLv2.1", "LICENSE.md", "NOTICE.md"):
        shutil.copyfile(PACKAGE / name, framework / name)
    (framework / "Info.plist").write_bytes(plistlib.dumps(framework_plist(pins, simulator), sort_keys=True))


def verify_binary(binary, expected_archs, expected_platform, minimum_ios, version):
    archs = run(["/usr/bin/xcrun", "lipo", "-archs", binary]).split()
    require(set(archs) == set(expected_archs), f"Unexpected architectures: {archs}")
    require(ROOT.as_posix().encode() not in binary.read_bytes(), "Binary embeds the user's repository path")
    require(version.encode() + b"\0" in binary.read_bytes(), "Pinned FFmpeg version string is missing")
    for arch in archs:
        header = run(["/usr/bin/xcrun", "otool", "-arch", arch, "-hv", binary])
        require(re.search(r"\bDYLIB\b", header), f"{arch} is not a dynamic library")
        load_commands = run(["/usr/bin/xcrun", "otool", "-arch", arch, "-l", binary])
        require("LC_UUID" in load_commands, f"{arch} lacks the UUID required by Apple's linker")
        symbol_lines = run(["/usr/bin/xcrun", "nm", "-arch", arch, "-gUj", binary]).splitlines()
        symbols = {line.strip() for line in symbol_lines if line.strip() and not line.endswith(":")}
        require(symbols == EXPORTED_SYMBOLS, f"Unexpected exports for {arch}: {sorted(symbols)}")
        build_info = run(["/usr/bin/xcrun", "vtool", "-arch", arch, "-show-build", binary])
        require(re.search(r"platform\s+" + expected_platform + r"\b", build_info),
                f"Wrong Apple platform for {arch}: {build_info}")
        require(re.search(r"minos\s+" + re.escape(minimum_ios) + r"(?:\.0)?\b", build_info),
                f"Wrong minimum OS for {arch}: {build_info}")
        dependencies = run(["/usr/bin/xcrun", "otool", "-arch", arch, "-L", binary])
        linked = set(re.findall(r"^\s+(.+?) \(compatibility version", dependencies, re.MULTILINE))
        require(INSTALL_NAME in linked and linked <= {INSTALL_NAME, "/usr/lib/libSystem.B.dylib"},
                f"Unexpected dynamic dependencies for {arch}: {sorted(linked)}")


def build_bridge(name, slice_root, environment, libraries, pins, args):
    files = wrapper_sources()
    compile_flags = ["-std=c11", "-Oz", "-fPIC", "-fvisibility=hidden", "-fno-ident",
                     "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations"]
    recipe = {
        "build_script_sha256": digest(Path(__file__)),
        "libraries_sha256": fingerprint(libraries),
        "wrapper": {path.relative_to(PACKAGE).as_posix(): digest(path) for path in files},
        "compile_flags": compile_flags,
        "link_flags": ["-dynamiclib", "-Wl,-dead_strip", "-Wl,-no_adhoc_codesign",
                       "-Wl,-install_name," + INSTALL_NAME, "-Wl,-compatibility_version,1.0.0",
                       "-Wl,-current_version,1.0.0", "-lm"],
        "plist": framework_plist(pins, SLICE_SPECS[name][0] == "iphonesimulator"),
    }
    recipe_hash = fingerprint(recipe)
    bridge_root = owned_directory(slice_root / "bridge" / recipe_hash[:20])
    framework = bridge_root / FRAMEWORK_NAME
    stamp = bridge_root / "bridge.json"
    if stamp.exists():
        record = read_json(stamp)
        if record["recipe"] == recipe and cache_files_match(framework, record["files"]):
            print(f"Bridge cached: {name}")
            return framework, record
    require(args.component in ("all", "bridge"),
            f"Bridge missing or stale for {name}; run --component bridge --slice {name}")
    build = slice_root / "build"
    staging = Path(tempfile.mkdtemp(prefix="link-", dir=bridge_root))
    staged_framework = staging / FRAMEWORK_NAME
    log = bridge_root / "bridge.log"
    try:
        write_framework_contents(staged_framework, pins, SLICE_SPECS[name][0] == "iphonesimulator")
        objects = []
        for source in sorted((PACKAGE / "Sources").glob("*.c")):
            target = staging / (source.stem + ".o")
            run([build / "apple-clang", *compile_flags, "-I", PACKAGE / "include", "-I",
                 slice_root / "install" / "include", "-c", source, "-o", target],
                cwd=build, env=environment, log=log)
            objects.append(target)
        archives = [slice_root / "install" / "lib" / f"lib{library}.a" for library in LIBRARIES]
        binary = staged_framework / "FFmpegBridge"
        print(f"Linking bridge: {name} (log: {log.relative_to(ROOT)})")
        run([build / "apple-clang", *objects, *archives, *recipe["link_flags"],
             "-Xlinker", "-exported_symbols_list", "-Xlinker", PACKAGE / "exports.txt", "-o", binary],
            cwd=build, env=environment, log=log)
        run(["/usr/bin/xcrun", "strip", "-S", "-x", binary], log=log)
        verify_binary(binary, [SLICE_SPECS[name][1]], SLICE_SPECS[name][3], pins["minimum_ios"], pins["version"])
        require(recipe["wrapper"] == {path.relative_to(PACKAGE).as_posix(): digest(path) for path in wrapper_sources()},
                "Bridge inputs changed during compilation; rerun the bridge component")
        record = {"recipe": recipe, "recipe_sha256": recipe_hash,
                  "files": {path.relative_to(staged_framework).as_posix(): digest(path)
                            for path in files_under(staged_framework)}}
        if framework.exists():
            framework.rename(bridge_root / ("previous-" + uuid.uuid4().hex))
        staged_framework.rename(framework)
        write_json(stamp, record)
        return framework, record
    finally:
        shutil.rmtree(staging)


def framework_checks(framework, simulator, pins):
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    require(info == framework_plist(pins, simulator), "Framework Info.plist does not match the recipe")
    require(digest(framework / "Headers" / "FFmpegBridge.h") == digest(PACKAGE / "include" / "FFmpegBridge.h"),
            "Framework header differs from the public API")
    require(digest(framework / "Modules" / "module.modulemap") == digest(PACKAGE / "Framework.modulemap"),
            "Framework module map differs from the package")
    for name in ("COPYING.LGPLv2.1", "LICENSE.md", "NOTICE.md"):
        require(digest(framework / name) == digest(PACKAGE / name), f"Framework {name} differs from the package")
    verify_binary(framework / "FFmpegBridge", ["arm64", "x86_64"] if simulator else ["arm64"],
                  "IOSSIMULATOR" if simulator else "IOS", pins["minimum_ios"], pins["version"])


def corresponding_source(source, pins, provenance, destination):
    # Fixed ordering, owners and timestamps keep the source distribution independent of the checkout path.
    items = [(path, f"ffmpeg-{pins['version']}/" + path.relative_to(source).as_posix())
             for path in files_under(source)]
    for path in files_under(PACKAGE):
        relative = path.relative_to(PACKAGE)
        if "FFmpegBridge.xcframework" in relative.parts or relative.name == "BUILD-PROVENANCE.json":
            continue
        items.append((path, "breezy-bridge/Vendor/FFmpegBridge/" + relative.as_posix()))
    items.append((Path(__file__), "breezy-bridge/tools/build-ffmpeg.py"))
    manifest = destination.parent / "source-provenance.json"
    write_json(manifest, provenance)
    items.append((manifest, "breezy-bridge/BUILD-PROVENANCE.json"))
    with tarfile.open(destination, "w:xz", format=tarfile.PAX_FORMAT) as archive:
        for path, name in sorted(items, key=lambda item: item[1]):
            info = archive.gettarinfo(str(path), arcname=name)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = pins["source_date_epoch"]
            info.mode = 0o755 if path.stat().st_mode & stat.S_IXUSR else 0o644
            info.pax_headers = {}
            with path.open("rb") as contents:
                archive.addfile(info, contents)


def xcframework_entries(xcframework):
    entries = plistlib.loads((xcframework / "Info.plist").read_bytes())["AvailableLibraries"]
    require(len(entries) == 2 and
            {entry.get("SupportedPlatformVariant", "device") for entry in entries} == {"device", "simulator"},
            "XCFramework must contain exactly device and simulator variants")
    for entry in entries:
        simulator = entry.get("SupportedPlatformVariant") == "simulator"
        require(entry["SupportedPlatform"] == "ios" and entry["LibraryPath"] == FRAMEWORK_NAME and
                set(entry["SupportedArchitectures"]) == ({"arm64", "x86_64"} if simulator else {"arm64"}),
                "Unexpected XCFramework platform, library path or architecture metadata")
        require(PurePosixPath(entry["LibraryIdentifier"]).parts == (entry["LibraryIdentifier"],),
                "Invalid XCFramework library identifier")
    return entries


def package_frameworks(frameworks, records, source, source_record, pins, args):
    inputs = {path.relative_to(PACKAGE).as_posix(): digest(path) for path in wrapper_sources()}
    require(fingerprint(tree_manifest(source)) == source_record["tree_sha256"], "Source changed during build")
    require(all(record["bridge"]["recipe"]["wrapper"] == inputs and
                record["bridge"]["recipe"]["build_script_sha256"] == digest(Path(__file__))
                for record in records.values()), "Bridge inputs changed between slices")
    staging = Path(tempfile.mkdtemp(prefix="package-", dir=WORK))
    try:
        device = staging / "device" / FRAMEWORK_NAME
        simulator = staging / "simulator" / FRAMEWORK_NAME
        shutil.copytree(frameworks["iphoneos-arm64"], device)
        shutil.copytree(frameworks["iphonesimulator-arm64"], simulator)
        run(["/usr/bin/xcrun", "lipo", "-create",
             frameworks["iphonesimulator-arm64"] / "FFmpegBridge",
             frameworks["iphonesimulator-x86_64"] / "FFmpegBridge",
             "-output", simulator / "FFmpegBridge"])
        provenance = {
            "schema": 1, "source": pins, "prepared_source": source_record,
            "build_script_sha256": digest(Path(__file__)),
            "slices": records, "simulator_ad_hoc_signed": args.sign_simulator,
            "linkage": "MH_DYLIB; private static libavformat/libavcodec/libavutil; two exported C symbols",
        }
        for framework, is_simulator in ((device, False), (simulator, True)):
            write_json(framework / "BUILD-PROVENANCE.json", provenance)
            framework_checks(framework, is_simulator, pins)
        if args.sign_simulator:
            run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                 "--identifier", "com.agraabhi.ganabajana.ffmpegbridge", simulator])
            run(["/usr/bin/codesign", "--verify", "--strict", simulator])
        xcframework = staging / "FFmpegBridge.xcframework"
        run(["/usr/bin/xcodebuild", "-create-xcframework", "-framework", device,
             "-framework", simulator, "-output", xcframework], log=WORK / "package.log")
        for name in ("COPYING.LGPLv2.1", "LICENSE.md", "NOTICE.md"):
            shutil.copyfile(PACKAGE / name, xcframework / name)
        for entry in xcframework_entries(xcframework):
            is_simulator = entry.get("SupportedPlatformVariant") == "simulator"
            framework_checks(xcframework / entry["LibraryIdentifier"] / entry["LibraryPath"], is_simulator, pins)
        artifact_files = {path.relative_to(xcframework).as_posix(): digest(path) for path in files_under(xcframework)}
        provenance["xcframework_files"] = artifact_files
        provenance["xcframework_payload_bytes"] = sum(path.stat().st_size for path in files_under(xcframework))
        write_json(xcframework / "BUILD-PROVENANCE.json", provenance)
        source_bundle = staging / f"FFmpegBridge-{pins['version']}-source.tar.xz"
        corresponding_source(source, pins, provenance, source_bundle)
        source_hash = digest(source_bundle)
        source_name = f"FFmpegBridge-{pins['version']}-source-{source_hash}.tar.xz"
        provenance["corresponding_source"] = {"file": source_name, "sha256": source_hash}
        write_json(xcframework / "BUILD-PROVENANCE.json", provenance)
        provenance["root_manifest_sha256"] = digest(xcframework / "BUILD-PROVENANCE.json")
        provenance["xcframework_bytes"] = sum(path.stat().st_size for path in files_under(xcframework))
        manifest = staging / "BUILD-PROVENANCE.json"
        write_json(manifest, provenance)

        source_target = WORK / source_name
        require(not source_target.is_symlink(), "Refusing symlinked corresponding source archive")
        if source_target.exists():
            require(digest(source_target) == source_hash, "Existing corresponding source archive has changed")
        else:
            source_bundle.rename(source_target)

        target = PACKAGE / "FFmpegBridge.xcframework"
        manifest_target = PACKAGE / "BUILD-PROVENANCE.json"
        require(not target.is_symlink() and not manifest_target.is_symlink(),
                "Refusing to replace a symlinked XCFramework or provenance file")
        backup = None
        manifest_backup = None
        if target.exists():
            backup = WORK / ("previous-" + uuid.uuid4().hex + ".xcframework")
            target.rename(backup)
        try:
            if manifest_target.exists():
                manifest_backup = WORK / ("previous-" + uuid.uuid4().hex + ".json")
                manifest_target.rename(manifest_backup)
            xcframework.rename(target)
            manifest.rename(manifest_target)
        except BaseException:
            if target.exists():
                target.rename(staging / "unpublished.xcframework")
            if backup:
                backup.rename(target)
            if manifest_backup:
                manifest_backup.rename(manifest_target)
            raise
        print(f"XCFramework: {target.relative_to(ROOT)}")
        print(f"XCFramework size: {provenance['xcframework_bytes'] / 1024 / 1024:.2f} MiB")
        print(f"Corresponding source: artifacts/FFmpegBuild/{source_name}")
        if backup:
            print(f"Previous binary preserved: {backup.relative_to(ROOT)}")
        if manifest_backup:
            print(f"Previous provenance preserved: {manifest_backup.relative_to(ROOT)}")
    finally:
        shutil.rmtree(staging)


def verify_package(pins):
    xcframework = PACKAGE / "FFmpegBridge.xcframework"
    recorded = read_json(PACKAGE / "BUILD-PROVENANCE.json")
    patch_hashes = {patch.name: digest(patch) for patch in sorted((PACKAGE / "Patches").glob("*.patch"))}
    require(recorded["build_script_sha256"] == digest(Path(__file__)),
            "The build recipe differs from the compiled bridge; rebuild before verifying")
    require(recorded["prepared_source"]["patches"] == patch_hashes and
            recorded["prepared_source"]["identity"].get("patch_policy") == 2,
            "The required source patches differ from the compiled bridge; rebuild before verifying")
    require(recorded["source"] == pins and cache_files_match(xcframework, recorded["xcframework_files"]),
            "XCFramework does not match its source or recorded file hashes")
    require(digest(xcframework / "BUILD-PROVENANCE.json") == recorded["root_manifest_sha256"],
            "XCFramework root provenance has changed")
    require({path.relative_to(xcframework).as_posix() for path in files_under(xcframework)} ==
            set(recorded["xcframework_files"]) | {"BUILD-PROVENANCE.json"}, "Unexpected XCFramework files")
    inputs = {path.relative_to(PACKAGE).as_posix(): digest(path) for path in wrapper_sources()}
    require(all(record["bridge"]["recipe"]["wrapper"] == inputs for record in recorded["slices"].values()),
            "The package source differs from the compiled bridge")
    for entry in xcframework_entries(xcframework):
        simulator = entry.get("SupportedPlatformVariant") == "simulator"
        framework = xcframework / entry["LibraryIdentifier"] / entry["LibraryPath"]
        framework_checks(framework, simulator, pins)
        if simulator and recorded["simulator_ad_hoc_signed"]:
            run(["/usr/bin/codesign", "--verify", "--strict", framework])
    print("Verified hashes, dynamic linkage, exports, architectures, platforms, headers, licenses and deployment targets.")


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", choices=("all", "source", "libraries", "bridge", "package", "verify"), default="all",
                        help="all builds selected slices then packages all three; other components are incremental")
    parser.add_argument("--slice", choices=tuple(SLICE_SPECS), action="append", dest="slices",
                        help="repeat to select slices; default is all three")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 1, 8))
    parser.add_argument("--sign-simulator", action="store_true", help="ad-hoc sign the combined simulator framework")
    parser.add_argument("--source-dir", type=Path,
                        help="explicit LGPL rebuild from modified FFmpeg 9.0.2 source; records its complete tree hash")
    result = parser.parse_args()
    require(1 <= result.jobs <= 64, "--jobs must be between 1 and 64")
    if result.source_dir:
        result.source_dir = result.source_dir.resolve(strict=True)
        require(result.source_dir.is_dir(), "--source-dir must be a directory")
    return result


def main():
    args = arguments()
    require(sys.version_info >= (3, 9), "Python 3.9 or newer is required")
    pins = read_json(PACKAGE / "Source.json")
    require(re.fullmatch(r"[0-9a-f]{64}", pins["sha256"]), "Invalid pinned source SHA-256")
    require(digest(PACKAGE / "COPYING.LGPLv2.1") == pins["lgpl_sha256"], "The verbatim LGPL text has changed")
    require(platform.system() == "Darwin" or args.component == "source", "Apple builds require macOS and Xcode")
    owned_directory(WORK)
    with build_lock():
        if args.component == "verify":
            verify_package(pins)
            return
        source, source_record = prepare_source(pins, args.source_dir)
        print(f"Source tree SHA-256: {source_record['tree_sha256']}")
        if args.component == "source":
            print(f"Prepared source: {source.relative_to(ROOT)}")
            return
        selected = set(args.slices or SLICE_SPECS)
        frameworks, records = {}, {}
        for name in SLICE_SPECS:
            if name not in selected and args.component not in ("all", "package"):
                continue
            effective = argparse.Namespace(**vars(args))
            if name not in selected:
                effective.component = "package"
            slice_root, environment, libraries = build_libraries(name, source, source_record, pins, effective)
            if args.component == "libraries":
                continue
            framework, bridge = build_bridge(name, slice_root, environment, libraries, pins, effective)
            frameworks[name] = framework
            records[name] = {"libraries": libraries, "bridge": bridge}
        if args.component in ("all", "package"):
            package_frameworks(frameworks, records, source, source_record, pins, args)


if __name__ == "__main__":
    try:
        main()
    except (BuildError, OSError, ValueError, tarfile.TarError) as error:
        print(f"build-ffmpeg: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("build-ffmpeg: interrupted; cached completed components are reusable", file=sys.stderr)
        sys.exit(130)
