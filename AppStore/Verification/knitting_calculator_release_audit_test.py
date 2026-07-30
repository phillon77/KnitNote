#!/usr/bin/env python3
"""Behavior tests for the Knitting Calculator release audit."""

from __future__ import annotations

import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
AUDIT_RELATIVE_PATH = Path(
    "AppStore/Verification/knitting_calculator_release_audit.sh"
)


class ReleaseAuditFixture:
    def __init__(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.bin = self.root / "fixture-bin"
        self._copy_repository_contract()
        self._write_command_fixtures()
        self._initialize_git_repository()

    def close(self) -> None:
        self.temporary_directory.cleanup()

    def _copy_repository_contract(self) -> None:
        shutil.copytree(REPOSITORY_ROOT / "KnittingCalculator", self.root / "KnittingCalculator")
        shutil.copytree(
            REPOSITORY_ROOT / "KnittingCalculatorTests",
            self.root / "KnittingCalculatorTests",
        )
        shutil.copytree(
            REPOSITORY_ROOT / "Packages/KnittingCalculatorCore",
            self.root / "Packages/KnittingCalculatorCore",
            ignore=shutil.ignore_patterns(".build"),
        )
        (self.root / "KnittingCalculator.xcodeproj").mkdir(parents=True)
        shutil.copy2(
            REPOSITORY_ROOT / "KnittingCalculator.xcodeproj/project.pbxproj",
            self.root / "KnittingCalculator.xcodeproj/project.pbxproj",
        )
        audit = self.root / AUDIT_RELATIVE_PATH
        audit.parent.mkdir(parents=True)
        shutil.copy2(REPOSITORY_ROOT / AUDIT_RELATIVE_PATH, audit)

        project_spec = self.root / "KnittingCalculator/project.yml"
        project_spec.write_text(
            project_spec.read_text(encoding="utf-8").replace(
                "CURRENT_PROJECT_VERSION: 1",
                "CURRENT_PROJECT_VERSION: 2",
            ),
            encoding="utf-8",
        )

        # Forbidden vocabulary in test fixtures must never be treated as a
        # production dependency.
        (self.root / "KnittingCalculatorTests/AuditVocabulary.swift").write_text(
            "let fixture = \"StoreKit URLSession Analytics tracking .binaryTarget\"",
            encoding="utf-8",
        )
        package_tests = (
            self.root
            / "Packages/KnittingCalculatorCore/Tests/KnittingCalculatorCoreTests"
            / "AuditVocabulary.swift"
        )
        package_tests.write_text(
            "let fixture = \"RevenueCat Firebase XCRemoteSwiftPackageReference\"",
            encoding="utf-8",
        )

    def _write_command_fixtures(self) -> None:
        self.bin.mkdir()
        self._write_executable(
            "xcodebuild",
            """#!/bin/bash
printf '%s\n' '{"project":{"targets":["KnittingCalculator","KnittingCalculatorTests"],"schemes":["KnittingCalculator"]}}'
""",
        )
        self._write_executable(
            "security",
            """#!/bin/bash
cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>9CFPAUL5N5</string></array>
<key>Entitlements</key><dict>
<key>application-identifier</key><string>9CFPAUL5N5.com.phillon.KnittingCalculator</string>
<key>com.apple.developer.team-identifier</key><string>9CFPAUL5N5</string>
<key>get-task-allow</key><false/>
<key>beta-reports-active</key><true/>
</dict>
</dict></plist>
PLIST
""",
        )
        self._write_executable(
            "codesign",
            """#!/bin/bash
if [[ "$*" == *"--entitlements :-"* ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>get-task-allow</key><false/></dict></plist>
PLIST
elif [[ "$*" == *"--verbose=4"* ]]; then
  printf '%s\n' 'Authority=Apple Distribution: Fixture (9CFPAUL5N5)' >&2
fi
exit 0
""",
        )

    def _write_executable(self, name: str, source: str) -> None:
        path = self.bin / name
        path.write_text(source, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _initialize_git_repository(self) -> None:
        subprocess.run(
            ["git", "init", "-q"],
            cwd=self.root,
            check=True,
            capture_output=True,
            text=True,
        )

    def run(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PATH"] = f"{self.bin}{os.pathsep}{environment['PATH']}"
        return subprocess.run(
            [str(self.root / AUDIT_RELATIVE_PATH), *arguments],
            cwd=self.root,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    def write_archive(
        self,
        *,
        bundle: str = "com.phillon.KnittingCalculator",
        version: str = "1.0.0",
        build: str = "2",
    ) -> Path:
        archive = self.root / "Fixture.xcarchive"
        if archive.exists():
            shutil.rmtree(archive)
        app = archive / "Products/Applications/KnittingCalculator.app"
        self._write_app_bundle(app, bundle=bundle, version=version, build=build)
        return archive

    def write_ipa(
        self,
        *,
        bundle: str = "com.phillon.KnittingCalculator",
        version: str = "1.0.0",
        build: str = "2",
    ) -> Path:
        payload_root = self.root / "ipa-source"
        if payload_root.exists():
            shutil.rmtree(payload_root)
        app = payload_root / "Payload/KnittingCalculator.app"
        self._write_app_bundle(app, bundle=bundle, version=version, build=build)
        ipa = self.root / "Fixture.ipa"
        ipa.unlink(missing_ok=True)
        with zipfile.ZipFile(ipa, "w") as archive:
            for path in payload_root.rglob("*"):
                archive.write(path, path.relative_to(payload_root))
        return ipa

    def _write_app_bundle(
        self,
        app: Path,
        *,
        bundle: str,
        version: str,
        build: str,
    ) -> None:
        app.mkdir(parents=True)
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle,
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": build,
                },
                stream,
            )
        shutil.copy2(
            self.root / "KnittingCalculator/PrivacyInfo.xcprivacy",
            app / "PrivacyInfo.xcprivacy",
        )
        (app / "Assets.car").write_bytes(b"fixture")
        (app / "embedded.mobileprovision").write_bytes(b"fixture")
        for locale in ("en", "zh-Hant"):
            localized = app / f"{locale}.lproj"
            localized.mkdir()
            (localized / "Localizable.strings").write_text(
                '"fixture" = "fixture";',
                encoding="utf-8",
            )
            (localized / "InfoPlist.strings").write_text(
                '"fixture" = "fixture";',
                encoding="utf-8",
            )


class KnittingCalculatorReleaseAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ReleaseAuditFixture()

    def tearDown(self) -> None:
        self.fixture.close()

    def assert_boundary_failure(
        self,
        expected_message: str,
    ) -> None:
        result = self.fixture.run("--static-only")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(expected_message, result.stderr)

    def test_valid_fixture_scans_only_production_sources(self) -> None:
        result = self.fixture.run("--static-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("KNITTING CALCULATOR RELEASE AUDIT: PASS", result.stdout)

    def test_rejects_commerce_in_app_production_source(self) -> None:
        source = self.fixture.root / "KnittingCalculator/App/Commerce.swift"
        source.write_text("import StoreKit\n", encoding="utf-8")
        self.assert_boundary_failure("commerce dependency")

    def test_rejects_analytics_in_linked_production_source(self) -> None:
        source = (
            self.fixture.root
            / "Packages/KnittingCalculatorCore/Sources/KnittingCalculatorCore/Analytics.swift"
        )
        source.write_text("import FirebaseAnalytics\n", encoding="utf-8")
        self.assert_boundary_failure("analytics or tracking dependency")

    def test_rejects_tracking_in_linked_production_source(self) -> None:
        source = (
            self.fixture.root
            / "Packages/KnittingCalculatorCore/Sources/KnittingCalculatorCore/Tracking.swift"
        )
        source.write_text("let tracking = \"fixture\"\n", encoding="utf-8")
        self.assert_boundary_failure("analytics or tracking dependency")

    def test_rejects_networking_in_linked_production_source(self) -> None:
        source = (
            self.fixture.root
            / "Packages/KnittingCalculatorCore/Sources/KnittingCalculatorCore/Network.swift"
        )
        source.write_text("let session = URLSession.shared\n", encoding="utf-8")
        self.assert_boundary_failure("networking dependency")

    def test_rejects_remote_package_declaration(self) -> None:
        project = self.fixture.root / "KnittingCalculator/project.yml"
        project.write_text(
            project.read_text(encoding="utf-8").replace(
                "packages:\n",
                "packages:\n"
                "  RemoteSDK:\n"
                "    url: https://example.com/remote-sdk.git\n"
                "    from: 1.0.0\n",
                1,
            ),
            encoding="utf-8",
        )
        self.assert_boundary_failure("dynamic package dependency")

    def test_rejects_remote_package_in_generated_project(self) -> None:
        project = self.fixture.root / "KnittingCalculator.xcodeproj/project.pbxproj"
        project.write_text(
            project.read_text(encoding="utf-8")
            + "\nXCRemoteSwiftPackageReference \"https://example.com/remote-sdk.git\";\n",
            encoding="utf-8",
        )
        self.assert_boundary_failure("dynamic package dependency")

    def test_rejects_remote_resolved_package(self) -> None:
        resolved = (
            self.fixture.root
            / "KnittingCalculator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
            / "Package.resolved"
        )
        resolved.parent.mkdir(parents=True)
        resolved.write_text(
            """{
  "originHash": "fixture",
  "pins": [{
    "identity": "remote-sdk",
    "kind": "remoteSourceControl",
    "location": "https://example.com/remote-sdk.git",
    "state": {"revision": "fixture", "version": "1.0.0"}
  }],
  "version": 3
}
""",
            encoding="utf-8",
        )
        self.assert_boundary_failure("dynamic package dependency")

    def test_rejects_binary_target_declaration(self) -> None:
        package = self.fixture.root / "Packages/KnittingCalculatorCore/Package.swift"
        package.write_text(
            package.read_text(encoding="utf-8")
            + '\nlet forbiddenBinary = Target.binaryTarget(name: "Vendor", path: "Vendor.xcframework")\n',
            encoding="utf-8",
        )
        self.assert_boundary_failure("binary framework dependency")

    def test_archive_rejects_wrong_identity_and_app_store_id(self) -> None:
        cases = (
            (
                {"bundle": "com.phillon.Wrong"},
                "archive bundle identifier is not com.phillon.KnittingCalculator",
            ),
            ({"version": "1.0.1"}, "archive marketing version is not 1.0.0"),
            ({"build": "1"}, "archive build number is not 2"),
        )
        for values, expected_message in cases:
            with self.subTest(values=values):
                archive = self.fixture.write_archive(**values)
                result = self.fixture.run("--archive", str(archive))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(expected_message, result.stderr)

        source = self.fixture.root / "KnittingCalculator/Model/CalculatorShareText.swift"
        source.write_text(
            source.read_text(encoding="utf-8").replace("6795877892", "6790000000"),
            encoding="utf-8",
        )
        archive = self.fixture.write_archive()
        result = self.fixture.run("--archive", str(archive))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("App Store ID is not 6795877892", result.stderr)

    def test_ipa_rejects_wrong_identity_and_app_store_id(self) -> None:
        cases = (
            (
                {"bundle": "com.phillon.Wrong"},
                "archive bundle identifier is not com.phillon.KnittingCalculator",
            ),
            ({"version": "1.0.1"}, "archive marketing version is not 1.0.0"),
            ({"build": "1"}, "archive build number is not 2"),
        )
        for values, expected_message in cases:
            with self.subTest(values=values):
                ipa = self.fixture.write_ipa(**values)
                result = self.fixture.run("--ipa", str(ipa))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(expected_message, result.stderr)

        source = self.fixture.root / "KnittingCalculator/Model/CalculatorShareText.swift"
        source.write_text(
            source.read_text(encoding="utf-8").replace("6795877892", "6790000000"),
            encoding="utf-8",
        )
        ipa = self.fixture.write_ipa()
        result = self.fixture.run("--ipa", str(ipa))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("App Store ID is not 6795877892", result.stderr)


if __name__ == "__main__":
    unittest.main()
