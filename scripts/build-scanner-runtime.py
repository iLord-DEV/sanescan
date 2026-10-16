#!/usr/bin/env python3
"""Build a relocatable SANE runtime, including corresponding source and licenses."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parent.parent
LOCK_FILE = ROOT / "scripts/scanner-runtime.lock.json"
LOCK = json.loads(LOCK_FILE.read_text())
ARCH = platform.machine()
BUILD = ROOT / "build/native" / (hashlib.sha256(LOCK_FILE.read_bytes()).hexdigest()[:12] + "-" + ARCH)
PREFIX = BUILD / "stage/sanescan-runtime"
OUTPUT = ROOT / "build/scanner-runtime"
DOWNLOADS = ROOT / "build/runtime-downloads"
LOG = ROOT / "build/scanner-runtime-build.log"


def run(command, cwd=None, environment=None):
    with LOG.open("ab") as log:
        log.write(("\n$ " + " ".join(map(str, command)) + "\n").encode())
        subprocess.run(list(map(str, command)), cwd=cwd, env=environment, stdout=log,
                       stderr=subprocess.STDOUT, check=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(package):
    path = DOWNLOADS / package["url"].split("/")[-1]
    if not path.is_file() or digest(path) != package["sha256"]:
        print("Downloading " + package["name"] + " " + package["version"], flush=True)
        temporary = path.with_suffix(path.suffix + ".partial")
        run(["curl", "--fail", "--location", "--retry", "3", "--silent", "--show-error",
             package["url"], "--output", temporary])
        if digest(temporary) != package["sha256"]:
            temporary.unlink()
            raise RuntimeError("Source checksum mismatch: " + package["name"])
        temporary.replace(path)
    return path


def source(package, archive):
    path = BUILD / "sources" / (package["name"] + "-" + package["version"])
    if not path.exists():
        # Check paths before passing the verified upstream archive to BSD tar.
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                if Path(member.name).is_absolute() or ".." in Path(member.name).parts:
                    raise RuntimeError("Unsafe source archive path")
        path.mkdir(parents=True)
        run(["tar", "-xf", archive, "--strip-components=1", "-C", path])
    return path


def dependencies(path):
    lines = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
    return [line.strip().split(" (compatibility version", 1)[0] for line in lines]


def relocate():
    files = [OUTPUT / "bin/scanimage"]
    files += [p for p in (OUTPUT / "lib").rglob("*") if p.is_file() and not p.is_symlink()]
    for path in files:
        if subprocess.run(["codesign", "-d", str(path)], capture_output=True).returncode == 0:
            run(["codesign", "--remove-signature", path])
        ids = subprocess.check_output(["otool", "-D", str(path)], text=True).splitlines()[1:]
        if ids:
            run(["install_name_tool", "-id", "@rpath/" + path.name, path])
        for dependency in dependencies(path):
            if dependency in ids or dependency == "@rpath/" + path.name:
                continue
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            candidates = [str(PREFIX), "/sanescan-runtime"]
            relative = next((dependency[len(p) + 1:] for p in candidates if dependency.startswith(p + "/")), None)
            if dependency.startswith("@rpath/"):
                relative = "lib/" + dependency.removeprefix("@rpath/")
            if relative is None:
                raise RuntimeError(f"Unexpected external dependency in {path.name}: {dependency}")
            target = OUTPUT / relative
            if not target.exists():
                raise RuntimeError("Missing runtime dependency: " + relative)
            local = "@loader_path/" + os.path.relpath(target, path.parent)
            run(["install_name_tool", "-change", dependency, local, path])
        load_commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
        lines = load_commands.splitlines()
        for index, line in enumerate(lines):
            if line.strip() == "cmd LC_RPATH":
                rpath = lines[index + 2].strip().removeprefix("path ").split(" (offset", 1)[0]
                if rpath.startswith((str(BUILD), "/sanescan-runtime", "/opt/homebrew", "/usr/local")):
                    run(["install_name_tool", "-delete_rpath", rpath, path])
        run(["codesign", "--force", "--sign", "-", path])


def main():
    if sys.platform != "darwin" or ARCH not in ("arm64", "x86_64"):
        raise RuntimeError("Build the scanner runtime on an Apple Silicon or Intel Mac")
    for tool in ("clang", "clang++", "make", "cmake", "pkg-config", "install_name_tool"):
        if not shutil.which(tool):
            raise RuntimeError(f"Missing build tool {tool}. Install CMake and pkg-config on the build machine.")
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    environment = dict(os.environ)
    for key in list(environment):
        if key.startswith(("DYLD_", "SANE_")) or key in ("CPATH", "LIBRARY_PATH", "CMAKE_PREFIX_PATH", "PKG_CONFIG_PATH"):
            del environment[key]
    flags = f"-O2 -g0 -mmacosx-version-min={LOCK['deployment_target']} -ffile-prefix-map={ROOT}=/SaneScanBuild"
    environment.update({
        "MACOSX_DEPLOYMENT_TARGET": LOCK["deployment_target"], "SDKROOT": sdk,
        "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++",
        "CFLAGS": flags, "CXXFLAGS": flags,
        "CPPFLAGS": f"-I{PREFIX}/include -I{sdk}/usr/include/libxml2",
        "LDFLAGS": f"-L{PREFIX}/lib -Wl,-headerpad_max_install_names",
        "PKG_CONFIG_LIBDIR": str(PREFIX / "lib/pkgconfig"),
        "libcurl_CFLAGS": "-I" + sdk + "/usr/include", "libcurl_LIBS": "-lcurl",
        "XML_CFLAGS": "-I" + sdk + "/usr/include/libxml2", "XML_LIBS": "-lxml2",
    })
    workers = str(min(os.cpu_count() or 2, 8))
    sources = []
    for package in LOCK["packages"]:
        archive = download(package)
        src = source(package, archive)
        sources.append((package, src, archive))
        obj = BUILD / "objects" / package["name"]
        obj.mkdir(parents=True, exist_ok=True)
        name = package["name"]
        configure = [str(src / "configure"), "--prefix=" + str(PREFIX), "--disable-static"]
        install = ["make", "install"]
        if name == "libusb":
            configure += ["--disable-examples-build", "--disable-tests-build"]
        elif name == "libpng":
            configure += ["--enable-shared"]
        elif name == "libtiff":
            configure += ["--disable-tools", "--disable-tests", "--disable-contrib", "--disable-docs",
                          "--disable-cxx", "--disable-lzma", "--disable-zstd", "--disable-webp",
                          "--disable-jbig", "--disable-lerc", "--disable-libdeflate"]
        elif name == "jpeg-turbo":
            configure = ["cmake", "-S", str(src), "-B", str(obj), "-DCMAKE_BUILD_TYPE=Release",
                         "-DCMAKE_INSTALL_PREFIX=" + str(PREFIX),
                         "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + LOCK["deployment_target"],
                         "-DCMAKE_OSX_SYSROOT=" + sdk, "-DCMAKE_C_FLAGS=" + flags,
                         "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-headerpad_max_install_names",
                         "-DENABLE_SHARED=ON", "-DENABLE_STATIC=OFF", "-DWITH_TURBOJPEG=OFF", "-DWITH_SIMD=OFF"]
        elif name == "sane-backends":
            configure = [str(src / "configure"), "--prefix=/sanescan-runtime", "--disable-static",
                         "--disable-nls", "--disable-preload", "--without-avahi", "--without-snmp",
                         "--without-systemd", "--without-gphoto2", "--without-v4l", "--without-poppler-glib",
                         "--with-usb-record-replay=yes", "--with-libcurl=yes", "--with-usb=yes"]
            install += ["DESTDIR=" + str(BUILD / "stage")]
        stamp = obj / ".complete"
        recipe = hashlib.sha256(json.dumps([configure, environment["CPPFLAGS"], environment["LDFLAGS"], flags]).encode()).hexdigest()
        if not stamp.exists() or stamp.read_text() != recipe:
            print("Building " + name + " for macOS " + LOCK["deployment_target"], flush=True)
            run(configure, cwd=obj, environment=environment)
            run(["make", "-j" + workers], cwd=obj, environment=environment)
            run(install, cwd=obj, environment=environment)
            stamp.write_text(recipe)
    print("Packaging and relocating scanner runtime", flush=True)
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    (OUTPUT / "bin").mkdir(parents=True)
    (OUTPUT / "lib").mkdir()
    shutil.copy2(PREFIX / "bin/scanimage", OUTPUT / "bin/scanimage")
    for path in (PREFIX / "lib").glob("*.dylib"):
        if path.is_symlink():
            (OUTPUT / "lib" / path.name).symlink_to(os.readlink(path))
        else:
            shutil.copy2(path, OUTPUT / "lib" / path.name)
    shutil.copytree(PREFIX / "lib/sane", OUTPUT / "lib/sane", symlinks=True,
                    ignore=shutil.ignore_patterns("*.la", "*.a"))
    shutil.copytree(PREFIX / "etc/sane.d", OUTPUT / "etc/sane.d")
    # Ship pristine defaults from this build, never the developer's scanner settings.
    available = {p.name.removeprefix("libsane-").removesuffix(".1.so") for p in (OUTPUT / "lib/sane").glob("*.1.so")}
    dll = OUTPUT / "etc/sane.d/dll.conf"
    dll.write_text("# Bundled SANE backends; test is enabled only by the verification tool.\n" +
                   "\n".join(sorted(available - {"dll", "test"})) + "\n")
    source_output = OUTPUT / "share/sources"
    licenses = OUTPUT / "share/licenses"
    source_output.mkdir(parents=True)
    licenses.mkdir(parents=True)
    for package, src, archive in sources:
        shutil.copy2(archive, source_output / archive.name)
        destination = licenses / package["name"]
        destination.mkdir()
        for path in src.iterdir():
            if path.is_file() and (path.name.upper().startswith(("COPYING", "COPYRIGHT", "LICENSE", "README", "AUTHORS"))):
                shutil.copy2(path, destination / path.name)
    shutil.copy2(Path(__file__), source_output / Path(__file__).name)
    shutil.copy2(LOCK_FILE, source_output / LOCK_FILE.name)
    (source_output / "REBUILD.md").write_text(
        "# Corresponding source for the bundled scanner runtime\n\n"
        "These are the unmodified upstream sources used to build this runtime. "
        "Their SHA-256 checksums, versions and download URLs are in scanner-runtime.lock.json. "
        "Licenses and notices are also available in ../licenses.\n\n"
        "To rebuild on a Mac with Xcode command line tools, Python 3, CMake and pkg-config:\n\n"
        "1. Create an empty working directory with scripts/ and build/runtime-downloads/.\n"
        "2. Copy build-scanner-runtime.py and scanner-runtime.lock.json into scripts/.\n"
        "3. Copy all source archives from this directory into build/runtime-downloads/.\n"
        "4. Run `python3 scripts/build-scanner-runtime.py` from the working directory.\n\n"
        "The script builds for the host architecture with a macOS 14 deployment target, "
        "relocates library references and ad-hoc signs the result in build/scanner-runtime/. "
        "No scanner settings or firmware from the build machine are included. "
        "Build options are recorded in the script; detailed output goes to build/scanner-runtime-build.log.\n"
    )
    relocate()
    (OUTPUT / "manifest.json").write_text(json.dumps({"architecture": ARCH, **LOCK}, indent=2) + "\n")
    print("Scanner runtime ready: " + str(OUTPUT.relative_to(ROOT)), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if LOG.exists():
            print("\n".join(LOG.read_text(errors="replace").splitlines()[-45:]), file=sys.stderr)
        sys.exit(1)
