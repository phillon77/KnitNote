import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from PIL import Image


VALIDATOR_PATH = Path(__file__).with_name("validate.py")
COMPOSITOR_PATH = Path(__file__).with_name("compose.py")
CAPTURE_PATH = Path(__file__).with_name("capture.sh")
spec = importlib.util.spec_from_file_location("calculator_screenshot_validate", VALIDATOR_PATH)
validate = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(validate)


class ScreenshotToolsTests(unittest.TestCase):
    def capture_environment(self):
        return {
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "iphoneDeviceTypeIdentifier": (
                "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max"
            ),
            "ipadDeviceTypeIdentifier": (
                "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
            ),
            "statusBarTime": "9:41",
            "cropSystemDate": True,
        }

    def make_valid_frames(self):
        frames = []
        scenes = {
            "iphone": ["home", "gauge", "adjustment", "privacy", "promotion"],
            "ipad": ["home", "gauge", "adjustment", "privacyPromotion"],
        }
        sizes = {"iphone": (1284, 2778), "ipad": (2064, 2752)}
        for locale in ("zh-Hant", "en"):
            for platform, platform_scenes in scenes.items():
                for index, scene in enumerate(platform_scenes, 1):
                    width, height = sizes[platform]
                    filenames = {
                        ("iphone", "promotion"): "05-knitnote.png",
                        ("ipad", "privacyPromotion"): "04-privacy-knitnote.png",
                    }
                    frames.append({
                        "locale": locale,
                        "platform": platform,
                        "scene": scene,
                        "device": "Test Device",
                        "width": width,
                        "height": height,
                        "headline": "編織尺寸" if locale == "zh-Hant" else "Knitting math",
                        "subheadline": "測試" if locale == "zh-Hant" else "Test copy",
                        "filename": filenames.get(
                            (platform, scene), f"{index:02d}-{scene}.png"
                        ),
                    })
        return frames

    def write_complete_fixture(self, mode="RGB"):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        frames = self.make_valid_frames()
        for frame in frames:
            for directory in ("Raw", "Generated"):
                path = root / directory / frame["locale"] / frame["platform"] / frame["filename"]
                path.parent.mkdir(parents=True, exist_ok=True)
                image = Image.new(
                    mode if directory == "Generated" else "RGB",
                    (frame["width"], frame["height"]),
                    "white",
                )
                image.save(path)
        return root, frames

    def test_valid_manifest_accepts_exact_bilingual_scope(self):
        frames = self.make_valid_frames()
        validate.validate_manifest(frames)

    def test_manifest_rejects_wrong_locale_platform_count(self):
        frames = self.make_valid_frames()
        frames.pop()
        with self.assertRaisesRegex(ValueError, "expected 18 frames"):
            validate.validate_manifest(frames)

    def test_manifest_rejects_wrong_pixel_size(self):
        frames = self.make_valid_frames()
        frames[0]["width"] = 1
        with self.assertRaisesRegex(ValueError, "incorrect dimensions"):
            validate.validate_manifest(frames)

    def test_manifest_rejects_non_object_payloads_and_frames(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        manifest_path = Path(temporary_directory.name) / "manifest.json"
        manifest_path.write_text("[]", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "payload must be an object"):
            validate.load_manifest(manifest_path)

        frames = self.make_valid_frames()
        frames[0] = []
        with self.assertRaisesRegex(ValueError, "frame 1 must be an object"):
            validate.validate_manifest(frames)

    def test_schema_two_manifest_requires_a_complete_capture_environment(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        manifest_path = Path(temporary_directory.name) / "manifest.json"
        payload = {
            "schemaVersion": 2,
            "captureEnvironment": self.capture_environment(),
            "frames": self.make_valid_frames(),
        }
        manifest_path.write_text(json.dumps(payload), encoding="utf-8")
        self.assertEqual(validate.load_manifest(manifest_path), payload["frames"])

        for missing_field in (
            "runtimeIdentifier",
            "iphoneDeviceTypeIdentifier",
            "ipadDeviceTypeIdentifier",
            "statusBarTime",
            "cropSystemDate",
        ):
            with self.subTest(missing_field=missing_field):
                invalid_payload = json.loads(json.dumps(payload))
                del invalid_payload["captureEnvironment"][missing_field]
                manifest_path.write_text(json.dumps(invalid_payload), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "captureEnvironment"):
                    validate.load_manifest(manifest_path)

    def test_manifest_rejects_unsafe_path_components(self):
        unsafe_values = (
            ("filename", "../escape.png"),
            ("filename", "/tmp/escape.png"),
            ("filename", "folder/escape.png"),
            ("filename", "folder\\escape.png"),
            ("filename", "."),
            ("filename", ".."),
            ("locale", "en\toutside"),
            ("platform", "iphone\noutside"),
        )
        for field, unsafe_value in unsafe_values:
            with self.subTest(field=field, unsafe_value=unsafe_value):
                frames = self.make_valid_frames()
                frames[0][field] = unsafe_value
                with self.assertRaisesRegex(ValueError, "safe path component"):
                    validate.validate_manifest(frames)

    def test_generated_image_must_be_opaque_rgb(self):
        root, frames = self.write_complete_fixture(mode="RGBA")
        with self.assertRaisesRegex(ValueError, "opaque RGB"):
            validate.validate_images(root, frames)

    def test_compositor_generates_an_opaque_b_frame_at_the_manifest_size(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        frame = {
            "locale": "en",
            "platform": "iphone",
            "scene": "home",
            "device": "iPhone",
            "width": 1284,
            "height": 2778,
            "headline": "Knitting math, made clear",
            "subheadline": "Free, offline, no account",
            "filename": "01-home.png",
        }
        manifest_path = root / "manifest.json"
        manifest_path.write_text(
            json.dumps({"schemaVersion": 1, "frames": [frame]}),
            encoding="utf-8",
        )
        raw_path = root / "Raw" / "en" / "iphone" / "01-home.png"
        raw_path.parent.mkdir(parents=True)
        raw = Image.new("RGB", (1284, 2778), (12, 34, 56))
        raw.save(raw_path)

        compositor_spec = importlib.util.spec_from_file_location(
            "calculator_screenshot_compose",
            COMPOSITOR_PATH,
        )
        compositor = importlib.util.module_from_spec(compositor_spec)
        assert compositor_spec.loader is not None
        compositor_spec.loader.exec_module(compositor)
        self.assertEqual(compositor.compose_manifest(manifest_path), 0)

        output_path = root / "Generated" / "en" / "iphone" / "01-home.png"
        with Image.open(output_path) as output:
            self.assertEqual(output.size, (1284, 2778))
            self.assertEqual(output.mode, "RGB")
            self.assertNotEqual(output.getpixel((0, 0)), raw.getpixel((0, 0)))
        self.assertTrue((root / "Generated" / "en" / "contact-sheet.png").is_file())

    def test_compositor_crops_the_ipad_system_date_region_without_repainting(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        width, height = 2064, 2752
        date_region_color = (3, 251, 7)
        app_region_color = (17, 29, 241)
        frame = {
            "locale": "en",
            "platform": "ipad",
            "scene": "home",
            "device": "iPad",
            "width": width,
            "height": height,
            "headline": "Knitting math, made clear",
            "subheadline": "Free, offline, no account",
            "filename": "01-home.png",
        }
        manifest_path = root / "manifest.json"
        manifest_path.write_text(
            json.dumps({
                "schemaVersion": 2,
                "captureEnvironment": self.capture_environment(),
                "frames": [frame],
            }),
            encoding="utf-8",
        )
        raw_path = root / "Raw" / "en" / "ipad" / "01-home.png"
        raw_path.parent.mkdir(parents=True)
        raw = Image.new("RGB", (width, height), app_region_color)
        date_region_height = int(height * 0.18)
        raw.paste(
            date_region_color,
            (0, 0, width, date_region_height),
        )
        raw.save(raw_path)

        compositor_spec = importlib.util.spec_from_file_location(
            "calculator_screenshot_compose_ipad_crop",
            COMPOSITOR_PATH,
        )
        compositor = importlib.util.module_from_spec(compositor_spec)
        assert compositor_spec.loader is not None
        compositor_spec.loader.exec_module(compositor)
        self.assertEqual(compositor.compose_manifest(manifest_path), 0)

        output_path = root / "Generated" / "en" / "ipad" / "01-home.png"
        ui_top = int(height * 0.18)
        with Image.open(output_path) as output:
            self.assertEqual(
                output.getpixel((width // 2, ui_top + 10)),
                app_region_color,
            )
            self.assertNotIn(date_region_color, output.getdata())

    def test_compositor_rejects_traversal_and_absolute_filenames(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        for unsafe_filename in ("../escaped.png", str(root / "absolute.png")):
            with self.subTest(unsafe_filename=unsafe_filename):
                frame = {
                    "locale": "en",
                    "platform": "iphone",
                    "scene": "home",
                    "device": "iPhone",
                    "width": 1284,
                    "height": 2778,
                    "headline": "Knitting math",
                    "subheadline": "Offline",
                    "filename": unsafe_filename,
                }
                manifest_path = root / "manifest.json"
                manifest_path.write_text(
                    json.dumps({"schemaVersion": 1, "frames": [frame]}),
                    encoding="utf-8",
                )
                escaped_raw = (
                    root / "Raw" / "en" / "escaped.png"
                    if unsafe_filename.startswith("..")
                    else Path(unsafe_filename)
                )
                escaped_raw.parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (1284, 2778), "white").save(escaped_raw)

                compositor_spec = importlib.util.spec_from_file_location(
                    "calculator_screenshot_compose_unsafe",
                    COMPOSITOR_PATH,
                )
                compositor = importlib.util.module_from_spec(compositor_spec)
                assert compositor_spec.loader is not None
                compositor_spec.loader.exec_module(compositor)
                with self.assertRaisesRegex(ValueError, "safe path component"):
                    compositor.compose_manifest(manifest_path)

    def write_capture_fixture(
        self,
        *,
        dedicated=True,
        screenshot_size=None,
        iphone_runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        ipad_runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        iphone_device_type=(
            "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max"
        ),
        ipad_device_type=(
            "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
        ),
    ):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        manifest = {
            "schemaVersion": 2,
            "captureEnvironment": self.capture_environment(),
            "frames": self.make_valid_frames(),
        }
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        app_path = root / "KnittingCalculator.app"
        app_path.mkdir()
        iphone_screenshot_path = root / "fake-iphone-screenshot.png"
        ipad_screenshot_path = root / "fake-ipad-screenshot.png"
        iphone_size, ipad_size = screenshot_size or ((1284, 2778), (2064, 2752))
        Image.new("RGB", iphone_size, "white").save(iphone_screenshot_path)
        Image.new("RGB", ipad_size, "white").save(ipad_screenshot_path)

        fake_bin = root / "bin"
        fake_bin.mkdir()
        record_path = root / "xcrun-record.tsv"
        device_prefix = "Knitting Calculator Store" if dedicated else "Personal"
        devices = {"devices": {}}
        for runtime, device in (
            (
                iphone_runtime,
                {
                    "name": f"{device_prefix} iPhone",
                    "udid": "IPHONE-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": iphone_device_type,
                },
            ),
            (
                ipad_runtime,
                {
                    "name": "Knitting Calculator Store iPad",
                    "udid": "IPAD-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": ipad_device_type,
                },
            ),
        ):
            devices["devices"].setdefault(runtime, []).append(device)
        devices_path = root / "devices.json"
        devices_path.write_text(json.dumps(devices), encoding="utf-8")
        fake_xcrun = fake_bin / "xcrun"
        fake_xcrun.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "$*" == "simctl list devices --json" ]]; then
                  printf '%s\\t' "$@" >> "$FAKE_XCRUN_RECORD"
                  printf '\\n' >> "$FAKE_XCRUN_RECORD"
                  /bin/cat "$FAKE_DEVICES_JSON"
                  exit 0
                fi
                printf '%s\\t' "$@" >> "$FAKE_XCRUN_RECORD"
                printf '\\n' >> "$FAKE_XCRUN_RECORD"
                if [[ "${1:-}" == "simctl" && "${2:-}" == "io" ]]; then
                  if [[ "${3:-}" == "IPAD-UDID" ]]; then
                    /bin/cp "$FAKE_IPAD_SCREENSHOT" "${5}"
                  else
                    /bin/cp "$FAKE_IPHONE_SCREENSHOT" "${5}"
                  fi
                elif [[ "${1:-}" == "simctl" && "${2:-}" == "spawn" && "${4:-}" == "log" ]]; then
                  printf '%s\\n' "$*"
                fi
                """
            ),
            encoding="utf-8",
        )
        fake_xcrun.chmod(fake_xcrun.stat().st_mode | stat.S_IXUSR)
        environment = os.environ.copy()
        environment.update({
            "PATH": f"{fake_bin}:{environment['PATH']}",
            "CALC_IPHONE_UDID": "IPHONE-UDID",
            "CALC_IPAD_UDID": "IPAD-UDID",
            "CALC_SCREENSHOT_APP": str(app_path),
            "CALC_SCREENSHOT_MANIFEST": str(manifest_path),
            "FAKE_DEVICES_JSON": str(devices_path),
            "FAKE_IPHONE_SCREENSHOT": str(iphone_screenshot_path),
            "FAKE_IPAD_SCREENSHOT": str(ipad_screenshot_path),
            "FAKE_XCRUN_RECORD": str(record_path),
            "SCREENSHOT_PYTHON": sys.executable,
            "SCREENSHOT_SETTLE_SECONDS": "0",
        })
        return root, environment, record_path

    def test_capture_refuses_a_non_dedicated_simulator_with_exit_two(self):
        _, environment, _ = self.write_capture_fixture(dedicated=False)
        result = subprocess.run(
            [str(CAPTURE_PATH), "en"],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_capture_operates_both_dedicated_devices_and_launches_the_fixture_scene(self):
        _, environment, record_path = self.write_capture_fixture()
        result = subprocess.run(
            [str(CAPTURE_PATH), "en"],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        invocations = record_path.read_text(encoding="utf-8").splitlines()
        self.assertTrue(any("simctl\terase\tIPHONE-UDID" in line for line in invocations))
        self.assertTrue(any("simctl\terase\tIPAD-UDID" in line for line in invocations))
        first_erase = next(
            index for index, line in enumerate(invocations)
            if "simctl\terase\t" in line
        )
        self.assertEqual(
            sum("simctl\tlist\tdevices\t--json" in line for line in invocations[:first_erase]),
            1,
        )
        self.assertTrue(any("simctl\tinstall\tIPHONE-UDID" in line for line in invocations))
        launch = next(
            line for line in invocations
            if "simctl\tlaunch\tIPHONE-UDID" in line
            and "-storeScreenshotScene\tgauge" in line
        )
        self.assertIn("com.phillon.KnittingCalculator", launch)
        self.assertIn("-storeScreenshotMode\tYES", launch)
        self.assertIn("-storeScreenshotScene\tgauge", launch)
        self.assertIn("-storeScreenshotLanguage\ten", launch)
        self.assertIn("-storeScreenshotToken\t", launch)
        self.assertTrue(any("simctl\tio\tIPHONE-UDID\tscreenshot" in line for line in invocations))

    def test_capture_rejects_a_screenshot_with_wrong_dimensions(self):
        _, environment, _ = self.write_capture_fixture(
            screenshot_size=((1, 1), (1, 1))
        )
        result = subprocess.run(
            [str(CAPTURE_PATH), "en"],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrong raw dimensions", result.stderr)

    def test_capture_rejects_manifest_dimensions_before_erasing_devices(self):
        root, environment, record_path = self.write_capture_fixture()
        manifest_path = root / "manifest.json"
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        payload["frames"][0]["width"] = 1
        manifest_path.write_text(json.dumps(payload), encoding="utf-8")

        result = subprocess.run(
            [str(CAPTURE_PATH), "en"],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 2, result.stderr)
        invocations = (
            record_path.read_text(encoding="utf-8")
            if record_path.exists()
            else ""
        )
        self.assertNotIn("simctl\terase\t", invocations)

    def test_capture_rejects_unsafe_filename_before_erasing_devices(self):
        root, environment, record_path = self.write_capture_fixture()
        manifest_path = root / "manifest.json"
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        payload["frames"][0]["filename"] = "../escaped.png"
        manifest_path.write_text(json.dumps(payload), encoding="utf-8")
        result = subprocess.run(
            [str(CAPTURE_PATH), "en"],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        invocations = (
            record_path.read_text(encoding="utf-8")
            if record_path.exists()
            else ""
        )
        self.assertNotIn("simctl\terase\t", invocations)

    def test_capture_parses_manifest_before_erasing_and_requires_locale_rows(self):
        for manifest_contents, locale in (("{", "en"), (None, "zh-Hant")):
            with self.subTest(manifest_contents=manifest_contents, locale=locale):
                root, environment, record_path = self.write_capture_fixture()
                if manifest_contents is not None:
                    (root / "manifest.json").write_text(
                        manifest_contents,
                        encoding="utf-8",
                    )
                else:
                    manifest_path = root / "manifest.json"
                    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
                    payload["frames"] = [
                        frame for frame in payload["frames"]
                        if frame["locale"] != "zh-Hant"
                    ]
                    manifest_path.write_text(json.dumps(payload), encoding="utf-8")
                result = subprocess.run(
                    [str(CAPTURE_PATH), locale],
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                invocations = (
                    record_path.read_text(encoding="utf-8")
                    if record_path.exists()
                    else ""
                )
                self.assertNotIn("simctl\terase\t", invocations)

    def test_capture_rejects_environment_or_matrix_errors_before_erasing(self):
        cases = {
            "iphone under the wrong runtime": {
                "fixture": {"iphone_runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-1"},
            },
            "ipad under the wrong runtime": {
                "fixture": {"ipad_runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-1"},
            },
            "iphone substring device lookalike": {
                "fixture": {
                    "iphone_device_type": (
                        "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max-Lookalike"
                    ),
                },
            },
            "ipad substring device lookalike": {
                "fixture": {
                    "ipad_device_type": (
                        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB-Lookalike"
                    ),
                },
            },
            "missing iphone type": {
                "remove_environment": "iphoneDeviceTypeIdentifier",
            },
            "missing ipad type": {
                "remove_environment": "ipadDeviceTypeIdentifier",
            },
            "missing runtime": {"remove_environment": "runtimeIdentifier"},
            "ipad crop exposes calendar": {"crop_system_date": False},
            "unapproved scene filename pair": {"filename": "99-gauge.png"},
        }
        for name, change in cases.items():
            with self.subTest(name=name):
                root, environment, record_path = self.write_capture_fixture(
                    **change.get("fixture", {})
                )
                manifest_path = root / "manifest.json"
                payload = json.loads(manifest_path.read_text(encoding="utf-8"))
                if "remove_environment" in change:
                    del payload["captureEnvironment"][change["remove_environment"]]
                if "crop_system_date" in change:
                    payload["captureEnvironment"]["cropSystemDate"] = change[
                        "crop_system_date"
                    ]
                if "filename" in change:
                    payload["frames"][1]["filename"] = change["filename"]
                manifest_path.write_text(json.dumps(payload), encoding="utf-8")

                result = subprocess.run(
                    [str(CAPTURE_PATH), "en"],
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                invocations = (
                    record_path.read_text(encoding="utf-8")
                    if record_path.exists()
                    else ""
                )
                self.assertNotIn("simctl\terase\t", invocations)


if __name__ == "__main__":
    unittest.main()
