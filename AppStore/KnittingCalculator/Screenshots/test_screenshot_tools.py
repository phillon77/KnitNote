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
                    frames.append({
                        "locale": locale,
                        "platform": platform,
                        "scene": scene,
                        "device": "Test Device",
                        "width": width,
                        "height": height,
                        "headline": "編織尺寸" if locale == "zh-Hant" else "Knitting math",
                        "subheadline": "測試" if locale == "zh-Hant" else "Test copy",
                        "filename": f"{index:02d}-{scene}.png",
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

    def write_capture_fixture(self, *, dedicated=True, screenshot_size=(1284, 2778)):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        manifest = {
            "schemaVersion": 1,
            "frames": [{
                "locale": "en",
                "platform": "iphone",
                "scene": "gauge",
                "device": "iPhone",
                "width": 1284,
                "height": 2778,
                "headline": "Gauge, stitches, and rows",
                "subheadline": "Enter a swatch and get the count",
                "filename": "01-gauge.png",
            }],
        }
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        app_path = root / "KnittingCalculator.app"
        app_path.mkdir()
        screenshot_path = root / "fake-screenshot.png"
        Image.new("RGB", screenshot_size, "white").save(screenshot_path)

        fake_bin = root / "bin"
        fake_bin.mkdir()
        record_path = root / "xcrun-record.tsv"
        device_prefix = "Knitting Calculator Store" if dedicated else "Personal"
        devices = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    {
                        "name": f"{device_prefix} iPhone",
                        "udid": "IPHONE-UDID",
                        "isAvailable": True,
                        "deviceTypeIdentifier":
                            "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max",
                    },
                    {
                        "name": "Knitting Calculator Store iPad",
                        "udid": "IPAD-UDID",
                        "isAvailable": True,
                        "deviceTypeIdentifier":
                            "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
                    },
                ],
            },
        }
        devices_path = root / "devices.json"
        devices_path.write_text(json.dumps(devices), encoding="utf-8")
        fake_xcrun = fake_bin / "xcrun"
        fake_xcrun.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "$*" == "simctl list devices --json" ]]; then
                  /bin/cat "$FAKE_DEVICES_JSON"
                  exit 0
                fi
                printf '%s\\t' "$@" >> "$FAKE_XCRUN_RECORD"
                printf '\\n' >> "$FAKE_XCRUN_RECORD"
                if [[ "${1:-}" == "simctl" && "${2:-}" == "io" ]]; then
                  /bin/cp "$FAKE_SCREENSHOT" "${5}"
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
            "FAKE_SCREENSHOT": str(screenshot_path),
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
        self.assertTrue(any("simctl\tinstall\tIPHONE-UDID" in line for line in invocations))
        launch = next(line for line in invocations if "simctl\tlaunch\tIPHONE-UDID" in line)
        self.assertIn("com.phillon.KnittingCalculator", launch)
        self.assertIn("-storeScreenshotMode\tYES", launch)
        self.assertIn("-storeScreenshotScene\tgauge", launch)
        self.assertIn("-storeScreenshotLanguage\ten", launch)
        self.assertIn("-storeScreenshotToken\t", launch)
        self.assertTrue(any("simctl\tio\tIPHONE-UDID\tscreenshot" in line for line in invocations))

    def test_capture_rejects_a_screenshot_with_wrong_dimensions(self):
        _, environment, _ = self.write_capture_fixture(screenshot_size=(1, 1))
        result = subprocess.run(
            [str(CAPTURE_PATH), "en"],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrong raw dimensions", result.stderr)


if __name__ == "__main__":
    unittest.main()
