#!/usr/bin/env python3
"""Behavior tests for the Knitting Calculator release audit."""

from __future__ import annotations

import os
import json
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
SOURCE_CHECK_RELATIVE_PATH = Path(
    "AppStore/Verification/knitting_calculator_release_source_check.py"
)
LOCALIZATION_CHECK_RELATIVE_PATH = Path(
    "AppStore/Verification/knitting_calculator_localization_check.py"
)
METADATA_CHECK_RELATIVE_PATH = Path("AppStore/Verification/metadata_check.py")
SUPPORTED_APP_LOCALES = (
    "da",
    "de",
    "el",
    "en",
    "fi",
    "fr",
    "ja",
    "ko",
    "nb",
    "nl",
    "sv",
    "zh-Hans",
    "zh-Hant",
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
        shutil.copy2(
            REPOSITORY_ROOT / SOURCE_CHECK_RELATIVE_PATH,
            self.root / SOURCE_CHECK_RELATIVE_PATH,
        )
        shutil.copy2(
            REPOSITORY_ROOT / LOCALIZATION_CHECK_RELATIVE_PATH,
            self.root / LOCALIZATION_CHECK_RELATIVE_PATH,
        )
        shutil.copy2(
            REPOSITORY_ROOT / METADATA_CHECK_RELATIVE_PATH,
            self.root / METADATA_CHECK_RELATIVE_PATH,
        )
        shutil.copytree(
            REPOSITORY_ROOT / "AppStore/KnittingCalculator/Metadata",
            self.root / "AppStore/KnittingCalculator/Metadata",
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
        version: str = "1.0.1",
        build: str = "3",
        artifact_app_store_id: str = "6795877892",
    ) -> Path:
        archive = self.root / "Fixture.xcarchive"
        if archive.exists():
            shutil.rmtree(archive)
        app = archive / "Products/Applications/KnittingCalculator.app"
        self._write_app_bundle(
            app,
            bundle=bundle,
            version=version,
            build=build,
            artifact_app_store_id=artifact_app_store_id,
        )
        return archive

    def write_ipa(
        self,
        *,
        bundle: str = "com.phillon.KnittingCalculator",
        version: str = "1.0.1",
        build: str = "3",
        artifact_app_store_id: str = "6795877892",
    ) -> Path:
        payload_root = self.root / "ipa-source"
        if payload_root.exists():
            shutil.rmtree(payload_root)
        app = payload_root / "Payload/KnittingCalculator.app"
        self._write_app_bundle(
            app,
            bundle=bundle,
            version=version,
            build=build,
            artifact_app_store_id=artifact_app_store_id,
        )
        ipa = self.root / "Fixture.ipa"
        ipa.unlink(missing_ok=True)
        with zipfile.ZipFile(ipa, "w") as archive:
            for path in payload_root.rglob("*"):
                archive.write(path, path.relative_to(payload_root))
        return ipa

    def remove_localized_resource(
        self,
        app: Path,
        locale: str,
        filename: str,
    ) -> None:
        (app / f"{locale}.lproj" / filename).unlink()

    def _write_app_bundle(
        self,
        app: Path,
        *,
        bundle: str,
        version: str,
        build: str,
        artifact_app_store_id: str,
    ) -> None:
        app.mkdir(parents=True)
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle,
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": build,
                    "CFBundleExecutable": "KnittingCalculator",
                },
                stream,
            )
        executable = app / "KnittingCalculator"
        executable.write_bytes(
            b"\x00fixture-binary\x00"
            + (
                "https://apps.apple.com/app/id"
                + artifact_app_store_id
            ).encode("ascii")
            + b"\x00"
        )
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
        shutil.copy2(
            self.root / "KnittingCalculator/PrivacyInfo.xcprivacy",
            app / "PrivacyInfo.xcprivacy",
        )
        (app / "Assets.car").write_bytes(b"fixture")
        (app / "embedded.mobileprovision").write_bytes(b"fixture")
        for locale in SUPPORTED_APP_LOCALES:
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

    def test_rejects_partially_updated_generated_project(self) -> None:
        project = self.fixture.root / "KnittingCalculator.xcodeproj/project.pbxproj"
        project.write_text(
            project.read_text(encoding="utf-8").replace(
                "MARKETING_VERSION = 1.0.1;",
                "MARKETING_VERSION = 1.0.0;",
                1,
            ),
            encoding="utf-8",
        )

        self.assert_boundary_failure(
            "generated project marketing version is not 1.0.1"
        )

    def test_rejects_generated_project_missing_supported_region(self) -> None:
        project = self.fixture.root / "KnittingCalculator.xcodeproj/project.pbxproj"
        project.write_text(
            project.read_text(encoding="utf-8").replace(
                "\t\t\t\t\"zh-Hant\",\n",
                "",
                1,
            ),
            encoding="utf-8",
        )

        self.assert_boundary_failure(
            "generated project known regions do not match supported app locales"
        )

    def test_rejects_commerce_in_app_production_source(self) -> None:
        source = self.fixture.root / "KnittingCalculator/App/Commerce.swift"
        source.write_text("import StoreKit\n", encoding="utf-8")
        self.assert_boundary_failure("commerce dependency")

    def test_rejects_legacy_storekit_commerce_in_rating_allowlist(self) -> None:
        source = self.fixture.root / "KnittingCalculator/Model/RatingEligibility.swift"
        source.write_text(
            source.read_text(encoding="utf-8")
            + "\nlet productsRequest: SKProductsRequest? = nil\n"
            + "let paymentQueue = SKPaymentQueue.default()\n",
            encoding="utf-8",
        )
        self.assert_boundary_failure("rating StoreKit surface")

    def test_rejects_modern_storekit_commerce_in_rating_allowlist(self) -> None:
        source = self.fixture.root / "KnittingCalculator/Model/RatingEligibility.swift"
        source.write_text(
            source.read_text(encoding="utf-8")
            + "\nlet subscriptionStore = SubscriptionStoreView(groupID: \"fixture\")\n",
            encoding="utf-8",
        )
        self.assert_boundary_failure("rating StoreKit surface")

    def test_rejects_external_purchase_storekit_surface_in_rating_allowlist(
        self,
    ) -> None:
        source = self.fixture.root / "KnittingCalculator/Model/RatingEligibility.swift"
        source.write_text(
            source.read_text(encoding="utf-8")
            + "\nimport struct StoreKit.ExternalPurchaseLink\n"
            + "let externalPurchaseLink: ExternalPurchaseLink? = nil\n",
            encoding="utf-8",
        )
        self.assert_boundary_failure("rating StoreKit surface")

    def test_rejects_advanced_commerce_storekit_surface_in_rating_allowlist(
        self,
    ) -> None:
        source = self.fixture.root / "KnittingCalculator/Model/RatingEligibility.swift"
        source.write_text(
            source.read_text(encoding="utf-8")
            + "\nimport struct StoreKit.AdvancedCommerceProduct\n"
            + "let advancedCommerceProduct: AdvancedCommerceProduct? = nil\n",
            encoding="utf-8",
        )
        self.assert_boundary_failure("rating StoreKit surface")

    def test_ignores_storekit_vocabulary_in_comments_and_strings(self) -> None:
        source = self.fixture.root / "KnittingCalculator/Model/RatingEligibility.swift"
        source.write_text(
            source.read_text(encoding="utf-8").replace(
                'as? String ?? "0"',
                'as? String ?? "AppStore.sync ExternalPurchaseLink"',
                1,
            )
            + "\n"
            + "// import struct StoreKit.AdvancedCommerceProduct\n"
            + "/* SubscriptionStoreView and Product are documentation only. */\n",
            encoding="utf-8",
        )

        result = self.fixture.run("--static-only")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_storekit_surface_inside_string_interpolation(self) -> None:
        source = self.fixture.root / "KnittingCalculator/Model/RatingEligibility.swift"
        source.write_text(
            source.read_text(encoding="utf-8").replace(
                '"0"',
                '"\\(ExternalPurchaseLink.self)"',
                1,
            ),
            encoding="utf-8",
        )
        self.assert_boundary_failure("rating StoreKit surface")

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

    def test_rejects_additional_linked_local_package(self) -> None:
        package_root = self.fixture.root / "Packages/LocalSDK"
        (package_root / "Sources/LocalSDK").mkdir(parents=True)
        (package_root / "Package.swift").write_text(
            """// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LocalSDK",
    products: [.library(name: "LocalSDK", targets: ["LocalSDK"])],
    targets: [.target(name: "LocalSDK")]
)
""",
            encoding="utf-8",
        )
        (package_root / "Sources/LocalSDK/LocalSDK.swift").write_text(
            "import Foundation\nlet session = URLSession.shared\n",
            encoding="utf-8",
        )
        project = self.fixture.root / "KnittingCalculator/project.yml"
        source = project.read_text(encoding="utf-8")
        source = source.replace(
            "packages:\n",
            "packages:\n"
            "  LocalSDK:\n"
            "    path: Packages/LocalSDK\n",
            1,
        )
        source = source.replace(
            "    dependencies:\n"
            "      - package: KnittingCalculatorCore\n",
            "    dependencies:\n"
            "      - package: KnittingCalculatorCore\n"
            "      - package: LocalSDK\n",
            1,
        )
        project.write_text(source, encoding="utf-8")
        self.assert_boundary_failure("linked local package dependency")

    def test_rejects_additional_local_package_in_generated_project(self) -> None:
        project = self.fixture.root / "KnittingCalculator.xcodeproj/project.pbxproj"
        project.write_text(
            project.read_text(encoding="utf-8").replace(
                "/* End XCLocalSwiftPackageReference section */",
                """\
		FIXTURE /* XCLocalSwiftPackageReference "Packages/LocalSDK" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/LocalSDK;
		};
/* End XCLocalSwiftPackageReference section */""",
                1,
            ),
            encoding="utf-8",
        )
        self.assert_boundary_failure("linked local package dependency")

    def test_rejects_additional_package_product_in_generated_project(self) -> None:
        project = self.fixture.root / "KnittingCalculator.xcodeproj/project.pbxproj"
        project.write_text(
            project.read_text(encoding="utf-8").replace(
                "/* End XCSwiftPackageProductDependency section */",
                """\
		FIXTURE /* SecondaryProduct */ = {
			isa = XCSwiftPackageProductDependency;
			productName = SecondaryProduct;
		};
/* End XCSwiftPackageProductDependency section */""",
                1,
            ),
            encoding="utf-8",
        )
        self.assert_boundary_failure("package product dependency")

    def test_rejects_nested_local_package_dependency(self) -> None:
        package = self.fixture.root / "Packages/KnittingCalculatorCore/Package.swift"
        package.write_text(
            package.read_text(encoding="utf-8").replace(
                "    products: [",
                "    dependencies: [.package(path: \"../LocalSDK\")],\n"
                "    products: [",
                1,
            ),
            encoding="utf-8",
        )
        self.assert_boundary_failure("linked local package dependency")

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

    def test_rejects_dynamic_library_product(self) -> None:
        package = self.fixture.root / "Packages/KnittingCalculatorCore/Package.swift"
        package.write_text(
            package.read_text(encoding="utf-8").replace(
                ".library(\n"
                "            name: \"KnittingCalculatorCore\",",
                ".library(\n"
                "            name: \"KnittingCalculatorCore\",\n"
                "            type: .dynamic,",
                1,
            ),
            encoding="utf-8",
        )
        self.assert_boundary_failure("dynamic library dependency")

    def test_rejects_multiline_dynamic_library_product(self) -> None:
        package = self.fixture.root / "Packages/KnittingCalculatorCore/Package.swift"
        package.write_text(
            package.read_text(encoding="utf-8").replace(
                ".library(\n"
                "            name: \"KnittingCalculatorCore\",",
                ".library(\n"
                "            name: \"KnittingCalculatorCore\",\n"
                "            type:\n"
                "                .dynamic,",
                1,
            ),
            encoding="utf-8",
        )
        self.assert_boundary_failure("dynamic library dependency")

    def test_static_only_propagates_localization_catalog_contract_failure(self) -> None:
        catalog = self.fixture.root / "KnittingCalculator/Localization/Localizable.xcstrings"
        payload = json.loads(catalog.read_text(encoding="utf-8"))
        del payload["strings"]["app.title"]["localizations"]["de"]
        catalog.write_text(json.dumps(payload), encoding="utf-8")

        self.assert_boundary_failure("app.title: locales: missing locales ['de']")

    def test_static_only_propagates_metadata_contract_failure(self) -> None:
        (self.fixture.root / "AppStore/KnittingCalculator/Metadata/de-DE.md").unlink()

        self.assert_boundary_failure("missing metadata locales: de-DE.md")

    def test_archive_rejects_missing_german_info_plist_strings(self) -> None:
        archive = self.fixture.write_archive()
        app = archive / "Products/Applications/KnittingCalculator.app"
        self.fixture.remove_localized_resource(app, "de", "InfoPlist.strings")

        result = self.fixture.run("--archive", str(archive))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("de.lproj/InfoPlist.strings", result.stderr)

    def test_ipa_rejects_missing_japanese_localizable_strings(self) -> None:
        ipa = self.fixture.write_ipa()
        payload = self.fixture.root / "ipa-source/Payload/KnittingCalculator.app"
        self.fixture.remove_localized_resource(payload, "ja", "Localizable.strings")
        ipa.unlink()
        with zipfile.ZipFile(ipa, "w") as archive:
            for path in (self.fixture.root / "ipa-source").rglob("*"):
                archive.write(path, path.relative_to(self.fixture.root / "ipa-source"))

        result = self.fixture.run("--ipa", str(ipa))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("ja.lproj/Localizable.strings", result.stderr)

    def test_archive_rejects_unexpected_locale_substituted_for_required_locale(self) -> None:
        archive = self.fixture.write_archive()
        app = archive / "Products/Applications/KnittingCalculator.app"
        self.fixture.remove_localized_resource(app, "de", "Localizable.strings")
        substituted = app / "it.lproj"
        substituted.mkdir()
        (substituted / "Localizable.strings").write_text(
            '"fixture" = "fixture";',
            encoding="utf-8",
        )
        (substituted / "InfoPlist.strings").write_text(
            '"fixture" = "fixture";',
            encoding="utf-8",
        )

        result = self.fixture.run("--archive", str(archive))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("de.lproj/Localizable.strings", result.stderr)

    def test_archive_rejects_incomplete_compiled_resources_after_source_contract_passes(self) -> None:
        static_result = self.fixture.run("--static-only")
        self.assertEqual(static_result.returncode, 0, static_result.stderr)

        archive = self.fixture.write_archive()
        app = archive / "Products/Applications/KnittingCalculator.app"
        self.fixture.remove_localized_resource(app, "fi", "Localizable.strings")
        result = self.fixture.run("--archive", str(archive))

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("fi.lproj/Localizable.strings", result.stderr)

    def test_archive_rejects_wrong_identity_and_app_store_id(self) -> None:
        cases = (
            (
                {"bundle": "com.phillon.Wrong"},
                "archive bundle identifier is not com.phillon.KnittingCalculator",
            ),
            ({"version": "1.0.0"}, "archive marketing version is not 1.0.1"),
            ({"build": "2"}, "archive build number is not 3"),
        )
        for values, expected_message in cases:
            with self.subTest(values=values):
                archive = self.fixture.write_archive(**values)
                result = self.fixture.run("--archive", str(archive))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(expected_message, result.stderr)

        archive = self.fixture.write_archive(artifact_app_store_id="6790000000")
        result = self.fixture.run("--archive", str(archive))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("artifact App Store ID is not 6795877892", result.stderr)

    def test_ipa_rejects_wrong_identity_and_app_store_id(self) -> None:
        cases = (
            (
                {"bundle": "com.phillon.Wrong"},
                "archive bundle identifier is not com.phillon.KnittingCalculator",
            ),
            ({"version": "1.0.0"}, "archive marketing version is not 1.0.1"),
            ({"build": "2"}, "archive build number is not 3"),
        )
        for values, expected_message in cases:
            with self.subTest(values=values):
                ipa = self.fixture.write_ipa(**values)
                result = self.fixture.run("--ipa", str(ipa))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(expected_message, result.stderr)

        ipa = self.fixture.write_ipa(artifact_app_store_id="6790000000")
        result = self.fixture.run("--ipa", str(ipa))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("artifact App Store ID is not 6795877892", result.stderr)

    def test_rejects_build_two_archive(self) -> None:
        archive = self.fixture.write_archive(version="1.0.0", build="2")
        result = self.fixture.run("--archive", str(archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive marketing version is not 1.0.1", result.stderr)


if __name__ == "__main__":
    unittest.main()
