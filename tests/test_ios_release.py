import hashlib
import importlib.util
import io
import os
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path
from tests.test_ci_concurrency import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ios_release", ROOT / "tools/ci/ios_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = "a" * 40
CLIENT_ID = "fixture-public-client"


def binary(signed=False, platform=2, legacy=False, file_type=2, minimum=0x100000):
    if platform is None:
        commands = b""
    elif legacy:
        commands = struct.pack("<IIII", 0x25, 16, minimum, 0x1B0000)
    else:
        commands = struct.pack("<IIIIII", 0x32, 24, platform, minimum, 0x1B0000, 0)
    count = int(platform is not None)
    if signed:
        commands += struct.pack("<IIII", 0x1D, 16, 48, 8)
        count += 1
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, file_type,
                       count, len(commands), 0, 0) + commands


def launcher_framework(version, build, executable="HorizonLauncherKit"):
    path = "Payload/Horizon.app/Frameworks/HorizonLauncherKit.framework"
    info = {"CFBundleShortVersionString": version, "CFBundleVersion": build,
            "CFBundleExecutable": executable}
    return {f"{path}/Info.plist": plistlib.dumps(info),
            f"{path}/{executable}": binary(file_type=6)}


class IOSReleaseTests(unittest.TestCase):
    def archive(self, path, extra=None, info=None, executable=None, omit_platform=False):
        metadata = {"CFBundleExecutable": "Horizon", "CFBundleShortVersionString": "0.1.0",
                    "CFBundleVersion": "42.2", "HorizonBuildCommit": SHA,
                    "CFBundleSupportedPlatforms": ["iPhoneOS"]}
        metadata.update(info or {})
        if omit_platform:
            metadata.pop("CFBundleSupportedPlatforms", None)
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("Payload/Horizon.app/Info.plist", plistlib.dumps(metadata))
            z.writestr("Payload/Horizon.app/Horizon", binary() if executable is None else executable)
            for name, data in (extra or {}).items():
                z.writestr(name, data)

    def test_device_metadata_cannot_disguise_a_non_device_macho(self):
        for platform in (1, 3, 4, 6, 7, 11):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                ipa = Path(directory) / "wrong-platform.ipa"
                self.archive(ipa, executable=binary(platform=platform))
                with self.assertRaisesRegex(ValueError, "iOS device"):
                    release.audit(ipa, SHA)

    def test_nested_framework_must_also_target_ios_devices(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "wrong-framework.ipa"
            self.archive(ipa, {"Payload/Horizon.app/Frameworks/Kit.framework/Kit":
                               binary(platform=7, file_type=6)})
            with self.assertRaisesRegex(ValueError, "iOS device"):
                release.audit(ipa, SHA)

    def test_missing_platform_and_truncated_build_tools_are_rejected(self):
        with self.assertRaises(ValueError):
            release.unsigned_macho(io.BytesIO(binary(platform=None)))
        malformed = bytearray(binary())
        struct.pack_into("<I", malformed, 52, 1)  # declares one missing build_tool_version
        with self.assertRaises(ValueError):
            release.unsigned_macho(io.BytesIO(malformed))

    def test_legacy_ios_device_minimum_version_command_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "legacy-device.ipa"
            self.archive(ipa, executable=binary(legacy=True))
            self.assertEqual(release.audit(ipa, SHA), ("0.1.0", "42.2"))

    def test_legacy_metadata_can_omit_platform_but_the_binary_cannot(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "manual-device.ipa"
            self.archive(ipa, omit_platform=True)
            self.assertEqual(release.audit(ipa, SHA), ("0.1.0", "42.2"))
            self.archive(ipa, executable=binary(platform=7), omit_platform=True)
            with self.assertRaisesRegex(ValueError, "iOS device"):
                release.audit(ipa, SHA)

    def test_workflow_versions_advance_but_retry_marketing_version_stays(self):
        for run, version in [(1, "0.1.44"), (88, "0.1.44"), (89, "0.1.45"),
                             (90, "0.1.46"), (91, "0.1.47")]:
            self.assertEqual(release.release_version(run, 1), (version, f"{run}.1"))
            self.assertEqual(release.release_version(run, 2), (version, f"{run}.2"))
        for run, attempt in [(0, 1), (88, 0), ("88\nkey=value", 1), ("x", 1)]:
            with self.assertRaises(ValueError):
                release.release_version(run, attempt)

    def test_release_rerun_checks_the_artifact_from_the_successful_build_attempt(self):
        jobs = yaml.safe_load((ROOT / ".github/workflows/ios.yml").read_text())["jobs"]
        build = jobs["ipa"]
        self.assertEqual(build["outputs"]["build-attempt"], "${{ github.run_attempt }}")
        self.assertEqual(build["outputs"]["artifact-id"], "${{ steps.upload-ipa.outputs.artifact-id }}")
        upload = next(step for step in build["steps"] if step.get("id") == "upload-ipa")
        self.assertIn("${{ github.run_attempt }}", upload["with"]["name"])
        steps = jobs["release"]["steps"]
        preflight = next(step for step in steps if step.get("name") == "Check the build artifact reference")
        download = next(step for step in steps if step.get("uses", "").startswith("actions/download-artifact@"))
        self.assertEqual(download["with"]["artifact-ids"], "${{ needs.ipa.outputs.artifact-id }}")
        self.assertTrue(download["with"]["merge-multiple"])
        prepare = next(step for step in steps if step.get("id") == "asset")
        self.assertEqual(prepare["env"]["IPA_BUILD_ATTEMPT"], "${{ needs.ipa.outputs.build-attempt }}")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tools").symlink_to(ROOT / "tools", target_is_directory=True)
            (root / "ipa-artifact").mkdir()
            ipa = root / "ipa-artifact/Horizon-game-unsigned.ipa"
            env = dict(os.environ, GITHUB_SHA=SHA, GITHUB_RUN_NUMBER="91", GITHUB_RUN_ATTEMPT="3",
                       GITHUB_OUTPUT=str(root / "outputs"), IPA_ARTIFACT_ID="987654",
                       IPA_BUILD_ATTEMPT="1", HORIZON_MSA_CLIENT_ID=CLIENT_ID)
            for overrides in ({"IPA_ARTIFACT_ID": ""}, {"IPA_BUILD_ATTEMPT": ""},
                              {"IPA_BUILD_ATTEMPT": "4"}):
                result = subprocess.run(["bash", "-ec", preflight["run"]],
                                        env=dict(env, **overrides), capture_output=True)
                self.assertNotEqual(result.returncode, 0, overrides)
            subprocess.run(["bash", "-ec", preflight["run"]], env=env, check=True)
            for artifact_attempt, build_attempt, accepted in [("1", "1", True), ("3", "3", True),
                                                               ("1", "3", False)]:
                with self.subTest(artifact=artifact_attempt, build=build_attempt):
                    version, number = release.release_version("91", artifact_attempt)
                    self.archive(ipa, launcher_framework(version, number),
                                 {"CFBundleShortVersionString": version, "CFBundleVersion": number,
                                  "HorizonMSAClientID": CLIENT_ID})
                    result = subprocess.run(["bash", "-ec", prepare["run"]], cwd=root,
                                            env=dict(env, IPA_BUILD_ATTEMPT=build_attempt),
                                            capture_output=True, text=True)
                    if accepted:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn(f"build={number}", (root / "outputs").read_text().splitlines())
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("IPA version does not match", result.stderr)

    def test_shipping_audit_requires_the_expected_launcher_path_and_client_id(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "release.ipa"
            version, build = "0.1.0", "42.2"
            for extra, client_id, problem in [
                ({}, CLIENT_ID, "Missing HorizonLauncherKit"),
                (launcher_framework(version, build, "Renamed"), CLIENT_ID, "Missing HorizonLauncherKit"),
                (launcher_framework(version, build), "", "Microsoft client ID"),
                (launcher_framework(version, build), CLIENT_ID, None),
            ]:
                with self.subTest(problem=problem):
                    self.archive(ipa, extra, {"HorizonMSAClientID": client_id})
                    options = {"require_launcher": True, "expected_client_id": CLIENT_ID}
                    if problem is not None:
                        with self.assertRaisesRegex(ValueError, problem):
                            release.audit(ipa, SHA, **options)
                    else:
                        self.assertEqual(release.audit(ipa, SHA, **options), (version, build))

    def test_stamp_updates_app_and_framework_preserving_other_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Game.app"
            framework = app / "Frameworks/Launcher.framework"
            framework.mkdir(parents=True)
            for parent in (app, framework):
                (parent / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "keep"}))
            release.stamp_app(app, "91", "2", SHA, "public-client")
            for parent in (app, framework):
                info = plistlib.loads((parent / "Info.plist").read_bytes())
                self.assertEqual(info["CFBundleShortVersionString"], "0.1.47")
                self.assertEqual(info["CFBundleVersion"], "91.2")
                self.assertEqual(info["CFBundleIdentifier"], "keep")
            info = plistlib.loads((app / "Info.plist").read_bytes())
            self.assertEqual(info["HorizonBuildCommit"], SHA)
            self.assertEqual(info["HorizonMSAClientID"], "public-client")

    def test_framework_version_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "input.ipa"
            self.archive(ipa, {"Payload/Horizon.app/Frameworks/Launcher.framework/Info.plist":
                              plistlib.dumps({"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"})})
            with self.assertRaisesRegex(ValueError, "Framework version"):
                release.audit(ipa, SHA)

    def test_framework_plist_must_describe_an_embedded_dylib(self):
        root = "Payload/Horizon.app/Frameworks/Launcher.framework"
        info = plistlib.dumps({"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "42.2",
                               "CFBundleExecutable": "Launcher"})
        for files, error in [
            ({f"{root}/Launcher": binary(file_type=6)}, "Missing framework Info.plist"),
            ({f"{root}/Info.plist": info}, "Missing unsigned ARM64 framework executable"),
            ({f"{root}/Info.plist": info, f"{root}/Launcher": binary()}, "framework executable"),
            ({f"{root}/Info.plist": info, f"{root}/Launcher": binary(file_type=6)}, None),
        ]:
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                ipa = Path(directory) / "framework.ipa"
                self.archive(ipa, files)
                if error is None:
                    self.assertEqual(release.audit(ipa, SHA), ("0.1.0", "42.2"))
                else:
                    with self.assertRaisesRegex(ValueError, error):
                        release.audit(ipa, SHA)

    def test_bundle_cannot_advertise_older_ios_than_its_code_requires(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "minimum.ipa"
            for legacy in (False, True):
                self.archive(ipa, info={"MinimumOSVersion": "16.0"},
                             executable=binary(legacy=legacy, minimum=0x110000))
                with self.assertRaisesRegex(ValueError, "App executable requires a newer iOS"):
                    release.audit(ipa, SHA)
            root = "Payload/Horizon.app/Frameworks/Launcher.framework"
            framework = {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "42.2",
                         "CFBundleExecutable": "Launcher", "MinimumOSVersion": "17.0"}
            self.archive(ipa, {f"{root}/Info.plist": plistlib.dumps(framework),
                               f"{root}/Launcher": binary(file_type=6, minimum=0x110000)},
                         info={"MinimumOSVersion": "16.0"})
            with self.assertRaisesRegex(ValueError, "Framework requires a newer iOS"):
                release.audit(ipa, SHA)

    def test_rejects_noncanonical_zip_member_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "aliased.ipa"
            self.archive(ipa, {"Payload/Horizon.app/./Horizon": binary()})
            with self.assertRaisesRegex(ValueError, "Unexpected IPA path"):
                release.audit(ipa, SHA)

    def test_payload_has_one_app_and_no_colliding_files_or_implicit_directories(self):
        bundle = "Payload/Horizon.app"
        cases = [
            ({"Payload/Other.app/stray.txt": b"extra"}, "outside the IPA application"),
            ({"Payload/stray.txt": b"extra"}, "outside the IPA application"),
            ({"Payload": b"not a directory"}, "also used as a directory"),
            ({f"{bundle}/INFO.PLIST": b"duplicate"}, "paths collide"),
            ({f"{bundle}/Assets/one": b"a", f"{bundle}/assets/two": b"b"}, "paths collide"),
            ({f"{bundle}/Café/one": b"a", f"{bundle}/Cafe\u0301/two": b"b"}, "paths collide"),
            ({f"{bundle}/Assets": b"file", f"{bundle}/Assets/one": b"a"}, "also used as a directory"),
        ]
        for entries, error in cases:
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as directory:
                ipa = Path(directory) / "layout.ipa"
                self.archive(ipa, entries)
                with self.assertRaisesRegex(ValueError, error):
                    release.audit(ipa, SHA)

    def test_payload_accepts_explicit_directories_and_distinct_bundle_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "layout.ipa"
            self.archive(ipa, {"Payload/": b"", "Payload/Horizon.app/": b"",
                               "Payload/Horizon.app/Assets/": b"",
                               "Payload/Horizon.app/Assets/One": b"one",
                               "Payload/Horizon.app/Assets/Two": b"two"})
            self.assertEqual(release.audit(ipa, SHA), ("0.1.0", "42.2"))

    def test_real_metadata_names_and_checksum_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "input.ipa"
            self.archive(ipa)
            result = release.prepare(ipa, root / "out", SHA)
            target = Path(result["ipa"])
            self.assertEqual(target.name, "Horizon-iOS-0.1.0-build42.2-unsigned.ipa")
            self.assertEqual(target.read_bytes(), ipa.read_bytes())
            self.assertEqual(Path(result["checksum"]).read_text(),
                             hashlib.sha256(ipa.read_bytes()).hexdigest() + "  " + target.name + "\n")

    def test_prepare_preserves_the_existing_pair_on_copy_or_audit_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "input.ipa"
            self.archive(ipa)
            output = root / "out"
            result = release.prepare(ipa, output, SHA)
            target, checksum = Path(result["ipa"]), Path(result["checksum"])
            before = target.read_bytes(), checksum.read_bytes()

            def interrupted_copy(_, destination):
                Path(destination).write_bytes(b"partial")
                raise OSError("simulated interrupted copy")

            with mock.patch.object(release.shutil, "copyfile", side_effect=interrupted_copy):
                with self.assertRaisesRegex(OSError, "interrupted copy"):
                    release.prepare(ipa, output, SHA)
            self.assertEqual((target.read_bytes(), checksum.read_bytes()), before)

            def copy_replaced_input(_, destination):
                self.archive(destination, info={"HorizonBuildCommit": "b" * 40})

            with mock.patch.object(release.shutil, "copyfile", side_effect=copy_replaced_input):
                with self.assertRaisesRegex(ValueError, "source commit"):
                    release.prepare(ipa, output, SHA)
            self.assertEqual((target.read_bytes(), checksum.read_bytes()), before)
            self.assertEqual(set(output.iterdir()), {target, checksum})

    def test_interrupted_pair_publication_never_leaves_an_old_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "input.ipa"
            self.archive(ipa)
            output = root / "out"
            result = release.prepare(ipa, output, SHA)
            target, checksum = Path(result["ipa"]), Path(result["checksum"])
            self.archive(ipa, {"Payload/Horizon.app/build.txt": b"replacement"})
            replace = Path.replace

            def fail_checksum(source, destination):
                if destination == checksum:
                    raise OSError("simulated checksum publication failure")
                return replace(source, destination)

            with mock.patch.object(Path, "replace", fail_checksum):
                with self.assertRaisesRegex(OSError, "checksum publication failure"):
                    release.prepare(ipa, output, SHA)
            self.assertEqual(target.read_bytes(), ipa.read_bytes())
            self.assertFalse(checksum.exists())
            self.assertEqual(release.prepare(ipa, output, SHA), result)
            self.assertIn(hashlib.sha256(target.read_bytes()).hexdigest(), checksum.read_text())

    def test_rejects_private_assets_profiles_and_paths(self):
        for name in ["horizon-resources.json", "horizon-data.bin", "embedded.mobileprovision",
                     "account.p12", "key.pem", ".env", "_CodeSignature/CodeResources",
                     "saves/level.dat", "servers.dat", "../outside", "/outside"]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                ipa = Path(directory) / "input.ipa"
                entry = name if name.startswith("/") else "Payload/Horizon.app/" + name
                self.archive(ipa, {entry: b"fixture"})
                with self.assertRaises(ValueError):
                    release.audit(ipa, SHA)

    def test_rejects_signed_main_and_nested_framework(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "input.ipa"
            self.archive(ipa, executable=binary(True))
            with self.assertRaisesRegex(ValueError, "signed binary"):
                release.audit(ipa, SHA)
            self.archive(ipa, {"Payload/Horizon.app/Frameworks/Kit.framework/Kit": binary(True)})
            with self.assertRaisesRegex(ValueError, "signed binary"):
                release.audit(ipa, SHA)

    def test_rejects_wrong_commit_and_unsafe_version(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "input.ipa"
            self.archive(ipa)
            with self.assertRaisesRegex(ValueError, "commit"):
                release.audit(ipa, "b" * 40)
            self.archive(ipa, info={"CFBundleVersion": "42\noutput=bad"})
            with self.assertRaisesRegex(ValueError, "version"):
                release.audit(ipa, SHA)

    def test_rejects_simulator_and_symlink_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "input.ipa"
            self.archive(ipa, info={"CFBundleSupportedPlatforms": ["iPhoneSimulator"]})
            with self.assertRaisesRegex(ValueError, "simulator"):
                release.audit(ipa, SHA)
            self.archive(ipa)
            with zipfile.ZipFile(ipa, "a") as z:
                link = zipfile.ZipInfo("Payload/Horizon.app/link")
                link.create_system = 3
                link.external_attr = 0o120777 << 16
                z.writestr(link, b"/outside")
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                release.audit(ipa, SHA)

    def test_main_must_be_an_executable_not_a_library(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "input.ipa"
            data = bytearray(binary())
            struct.pack_into("<I", data, 12, 6)
            self.archive(ipa, executable=data)
            with self.assertRaisesRegex(ValueError, "executable"):
                release.audit(ipa, SHA)

    def test_rejects_corrupt_payload_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "input.ipa"
            self.archive(ipa, {"Payload/Horizon.app/data.txt": b"A" * (1 << 15) + b"unchanged"})
            data = ipa.read_bytes().replace(b"unchanged", b"Xnchanged", 1)
            ipa.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "corrupt"):
                release.audit(ipa, SHA)

    def test_rejects_malformed_binary_instead_of_assuming_unsigned(self):
        for data in [binary()[:10], binary()[:16] + struct.pack("<II", 1, 0) + binary()[24:],
                     struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 8, 0, 0)
                     + struct.pack("<II", 1, 0)]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                release.unsigned_macho(io.BytesIO(data))

class PublishFlowTests(unittest.TestCase):
    def run_flow(self, scenario, tag_sha=SHA):
        import json
        import os
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mock = root / "gh"
            mock.write_text('''#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as f: f.write(json.dumps(args)+"\\n")
scenario=os.environ["SCENARIO"]
if args[0]=="api":
    if "matching-refs" in args[1]:
        if scenario not in ("new", "draft", "draft-wrong-target", "published-no-tag", "upload-failed", "upload-missing"):
            print("refs/tags/ios-build-42.2")
    elif args[1].endswith("/releases/latest"):
        if scenario == "latest-network-error": sys.exit(1)
        status = {"no-latest": "404 Not Found", "latest-server-error": "503 Service Unavailable"}.get(scenario, "200 OK")
        sys.stdout.write(f"HTTP/2.0 {status}\\nContent-Type: application/json\\r\\n\\r\\n")
        if not status.startswith("200"): sys.exit(1)
        if scenario != "latest-invalid":
            print(json.dumps({"tag_name":{"older":"ios-build-99.1", "local-newer":"v0.1.62", "local-older":"v0.0.1", "local-equal":"v0.1.0"}.get(scenario,"ios-build-41.1")}))
    else:
        assert args[1].endswith("/commits/tags/ios-build-42.2"), args
        moved = scenario == "tag-moved-during-upload" and Path("fixture-uploaded").exists()
        print("b" * 40 if moved else os.environ["TAG_SHA"])
elif args[:2]==["release","view"]:
    uploaded = Path("fixture-uploaded").exists()
    if not uploaded and scenario in ["new", "upload-failed", "wrong-tag", "upload-missing"]: sys.exit(1)
    names = ["game.ipa", "game.ipa.sha256"] if uploaded or scenario != "incomplete" else []
    if uploaded and scenario == "upload-missing":
        names.remove("game.ipa.sha256")
    if scenario in ("legacy", "upload-mismatch", "tag-moved-during-upload") and not uploaded: names=["Horizon-iOS-0.1.0-build42.2-unsigned.ipa", "Horizon-iOS-0.1.0-build42.2-unsigned.ipa.sha256", "other.txt", "Horizon-iOS-0.1.0-build41.1-unsigned.ipa"]
    assets = []
    for name in names:
        if name == "game.ipa.sha256" and not uploaded and scenario in ("starter", "partial-mismatch"):
            assets.append({"name": name, "state": "starter", "size": 0})
            continue
        content = Path(name).read_bytes() if Path(name).exists() else b"other"
        if name == "game.ipa" and scenario in ("partial-mismatch", "published-mismatch"):
            content = b"another build"
        if name == "game.ipa.sha256" and uploaded and scenario == "upload-mismatch":
            content = b"another checksum"
        assets.append({"name": name, "state": "uploaded", "size": len(content),
                       "digest": "sha256:" + hashlib.sha256(content).hexdigest()})
    target = "main" if scenario in ("tagged-with-branch-target", "draft-wrong-target") else os.environ["GITHUB_SHA"]
    print(json.dumps({"isDraft": scenario in ("draft", "draft-wrong-target"),
                      "targetCommitish": target, "assets": assets}))
elif args[:2]==["release","upload"]:
    if scenario == "upload-failed": sys.exit(1)
    Path("fixture-uploaded").touch()
''')
            mock.chmod(0o755)
            (root / "game.ipa").write_bytes(b"fixture app")
            (root / "game.ipa.sha256").write_text("fixture checksum\n")
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       GH_REPO="example/repository", GITHUB_SHA=SHA, IPA="game.ipa",
                       CHECKSUM="game.ipa.sha256", VERSION="0.1.0", BUILD="42.2",
                       SCENARIO=scenario, TAG_SHA=tag_sha, CALL_LOG=str(root / "calls"))
            result = subprocess.run(["bash", str(ROOT / "tools/ci/publish-ios-release.sh")],
                                    cwd=root, env=env, capture_output=True, text=True)
            self.assertTrue((root / "calls").exists(), result.stderr)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
            return result, calls

    def test_new_release_publishes_only_after_upload(self):
        result, calls = self.run_flow("new")
        self.assertEqual(result.returncode, 0, result.stderr)
        actions = [c[1] for c in calls if c[0] == "release"]
        self.assertEqual(actions, ["view", "create", "upload", "view", "edit"])
        create = next(c for c in calls if c[:2] == ["release", "create"])
        self.assertIn("--draft", create)
        result, calls = self.run_flow("upload-failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ["release", "edit"] for c in calls))

    def test_draft_resume_and_published_assets_are_not_overwritten(self):
        result, calls = self.run_flow("draft")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[:2] == ["release", "create"] for c in calls))
        self.assertTrue(any(c[:2] == ["release", "edit"] for c in calls))
        result, calls = self.run_flow("published")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[:2] == ["release", "upload"] for c in calls))
        edit = next(c for c in calls if c[:2] == ["release", "edit"])
        self.assertIn("--prerelease=false", edit)
        self.assertIn("--latest=true", edit)
        self.assertIn("Horizon iOS 0.1.0 — build 42.2", edit)

    def test_mismatched_published_assets_are_left_untouched(self):
        result, calls = self.run_flow("published-mismatch")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match this build", result.stderr)
        self.assertEqual([call[1] for call in calls if call[0] == "release"], ["view"])

    def test_unverified_uploads_cannot_publish_or_retire_downloads(self):
        for scenario in ("upload-missing", "upload-mismatch"):
            with self.subTest(scenario=scenario):
                result, calls = self.run_flow(scenario)
                self.assertNotEqual(result.returncode, 0)
                actions = [call[1] for call in calls if call[0] == "release"]
                self.assertIn("upload", actions)
                self.assertEqual(actions[-1], "view")
                self.assertNotIn("delete-asset", actions)
                self.assertNotIn("edit", actions)

    def test_wrong_tag_fails_closed(self):
        for scenario in ["wrong-tag"]:
            result, calls = self.run_flow(scenario, "b" * 40)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(c[:2] in [["release", "upload"], ["release", "edit"]] for c in calls))

    def test_existing_tag_takes_precedence_over_release_branch_metadata(self):
        result, calls = self.run_flow("tagged-with-branch-target")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[:2] == ["release", "edit"] for call in calls))
        for scenario in ("draft-wrong-target", "published-no-tag"):
            with self.subTest(scenario=scenario):
                result, calls = self.run_flow(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([call[1] for call in calls if call[0] == "release"], ["view"])

    def test_tag_moved_during_upload_blocks_promotion_and_asset_removal(self):
        result, calls = self.run_flow("tag-moved-during-upload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different commit", result.stdout)
        actions = [call[1] for call in calls if call[0] == "release"]
        self.assertIn("upload", actions)
        self.assertNotIn("delete-asset", actions)
        self.assertNotIn("edit", actions)

    def test_legacy_assets_repair_only_this_build_after_upload(self):
        result, calls = self.run_flow("legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        upload = next(i for i, c in enumerate(calls) if c[:2] == ["release", "upload"])
        deletes = [(i, c) for i, c in enumerate(calls) if c[:2] == ["release", "delete-asset"]]
        self.assertEqual(len(deletes), 2)
        self.assertTrue(all(i > upload and "build42.2-unsigned.ipa" in c[3] for i, c in deletes))
        result, calls = self.run_flow("incomplete")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[:2] == ["release", "upload"] for c in calls))

    def test_retry_of_older_run_does_not_replace_latest(self):
        result, calls = self.run_flow("older")
        self.assertEqual(result.returncode, 0, result.stderr)
        edit = next(c for c in calls if c[:2] == ["release", "edit"])
        self.assertIn("--latest=false", edit)

    def test_latest_lookup_errors_prevent_release_mutations(self):
        for scenario in ("latest-network-error", "latest-server-error", "latest-invalid"):
            with self.subTest(scenario=scenario):
                result, calls = self.run_flow(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == "release" for call in calls))
        result, calls = self.run_flow("no-latest")
        self.assertEqual(result.returncode, 0, result.stderr)
        edit = next(c for c in calls if c[:2] == ["release", "edit"])
        self.assertIn("--latest=true", edit)

    def test_repair_replaces_the_starter_asset_without_overwriting_a_verified_ipa(self):
        result, calls = self.run_flow("starter")
        self.assertEqual(result.returncode, 0, result.stderr)
        upload = next(c for c in calls if c[:2] == ["release", "upload"])
        self.assertEqual(upload[3:], ["game.ipa.sha256", "--clobber"])
        result, calls = self.run_flow("partial-mismatch")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match this build", result.stderr)
        self.assertFalse(any(c[:2] in [["release", "upload"], ["release", "edit"]] for c in calls))

    def test_local_versioned_release_is_not_replaced_by_an_older_ci_build(self):
        for scenario, latest in [("local-newer", "false"), ("local-older", "true"), ("local-equal", "false")]:
            result, calls = self.run_flow(scenario)
            self.assertEqual(result.returncode, 0, result.stderr)
            edit = next(c for c in calls if c[:2] == ["release", "edit"])
            self.assertIn("--latest=" + latest, edit)


if __name__ == "__main__":
    unittest.main()
