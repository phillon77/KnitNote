import importlib.util
import hashlib
import json
import os
import shutil
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
if str(COMPOSITOR_PATH.parent) not in sys.path:
    sys.path.insert(0, str(COMPOSITOR_PATH.parent))
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

    def write_first_frame_fixture(self, generated_mode="RGB"):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        frames = self.make_valid_frames()
        frame = frames[0]
        for directory, mode in (("Raw", "RGB"), ("Generated", generated_mode)):
            path = root / directory / frame["locale"] / frame["platform"] / frame["filename"]
            path.parent.mkdir(parents=True, exist_ok=True)
            Image.new(mode, (frame["width"], frame["height"]), "white").save(path)
        return root, frames

    def write_raw_image(self, root, frame, color="white"):
        path = root / "Raw" / frame["locale"] / frame["platform"] / frame["filename"]
        path.parent.mkdir(parents=True, exist_ok=True)
        Image.new("RGB", (frame["width"], frame["height"]), color).save(path)
        return path

    def write_raw_fixture(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        frames = self.make_valid_frames()
        manifest_path = root / "manifest.json"
        manifest_path.write_text(
            json.dumps({
                "schemaVersion": 2,
                "captureEnvironment": self.capture_environment(),
                "frames": frames,
            }),
            encoding="utf-8",
        )
        return root, frames, manifest_path

    def load_compositor(self, name):
        compositor_spec = importlib.util.spec_from_file_location(
            name,
            COMPOSITOR_PATH,
        )
        compositor = importlib.util.module_from_spec(compositor_spec)
        assert compositor_spec.loader is not None
        compositor_spec.loader.exec_module(compositor)
        return compositor

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

    def test_manifest_rejects_a_count_preserving_unapproved_scene_or_filename(self):
        for field, value in (
            ("scene", "unexpected"),
            ("filename", "05-unexpected.png"),
        ):
            with self.subTest(field=field):
                frames = self.make_valid_frames()
                frames[4][field] = value
                with self.assertRaisesRegex(ValueError, "approved frame matrix"):
                    validate.validate_manifest(frames)

    def test_manifest_rejects_approved_frames_in_the_wrong_order(self):
        frames = self.make_valid_frames()
        frames[0], frames[1] = frames[1], frames[0]
        with self.assertRaisesRegex(ValueError, "approved frame matrix"):
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
        root, frames = self.write_first_frame_fixture(generated_mode="RGBA")
        with self.assertRaisesRegex(ValueError, "opaque RGB"):
            validate.validate_images(root, frames)

    def test_validator_fully_decodes_a_png_with_a_valid_header(self):
        root, frames = self.write_first_frame_fixture()
        raw_path = root / "Raw" / "zh-Hant" / "iphone" / "01-home.png"
        raw_path.write_bytes(raw_path.read_bytes()[:-20])
        with self.assertRaisesRegex(ValueError, "cannot decode raw PNG"):
            validate.validate_images(root, frames)

    def test_validator_rejects_raw_or_generated_paths_resolving_outside_manifest_root(self):
        for directory in ("Raw", "Generated"):
            with self.subTest(directory=directory):
                root, frames = self.write_first_frame_fixture()
                source = root / directory / frames[0]["locale"]
                outside_root = Path(tempfile.mkdtemp(prefix=f"outside-{directory.lower()}-"))
                self.addCleanup(shutil.rmtree, outside_root, ignore_errors=True)
                outside = outside_root / "en"
                shutil.copytree(source, outside)
                shutil.rmtree(source)
                source.symlink_to(outside, target_is_directory=True)
                with self.assertRaisesRegex(ValueError, "resolves outside expected root"):
                    validate.validate_images(root, frames)

    def test_validator_rejects_raw_or_generated_root_symlinks_outside_manifest_root(self):
        for directory in ("Raw", "Generated"):
            with self.subTest(directory=directory):
                root, frames = self.write_first_frame_fixture()
                source = root / directory
                outside_root = Path(tempfile.mkdtemp(prefix=f"outside-{directory.lower()}-root-"))
                self.addCleanup(shutil.rmtree, outside_root, ignore_errors=True)
                outside = outside_root / directory
                shutil.copytree(source, outside)
                shutil.rmtree(source)
                source.symlink_to(outside, target_is_directory=True)
                with self.assertRaisesRegex(ValueError, "symlinked .* root"):
                    validate.validate_images(root, frames)

    def test_validator_rejects_unlisted_numbered_png_files(self):
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        frames = self.make_valid_frames()
        extra = root / "Raw" / "en" / "iphone" / "99-unlisted.png"
        extra.parent.mkdir(parents=True)
        Image.new("RGB", (1284, 2778), "white").save(extra)
        with self.assertRaisesRegex(ValueError, "unlisted numbered raw PNG"):
            validate.validate_images(root, frames)

    def test_compositor_generates_an_opaque_b_frame_at_the_manifest_size(self):
        root, _, manifest_path = self.write_raw_fixture()
        raw_path = root / "Raw" / "en" / "iphone" / "01-home.png"
        raw_path.parent.mkdir(parents=True)
        raw = Image.new("RGB", (1284, 2778), (12, 34, 56))
        raw.save(raw_path)
        compositor = self.load_compositor("calculator_screenshot_compose")
        frame = next(
            frame for frame in self.make_valid_frames()
            if frame["locale"] == "en" and frame["platform"] == "iphone"
            and frame["filename"] == "01-home.png"
        )
        compositor.compose_frame(frame, root)

        output_path = root / "Generated" / "en" / "iphone" / "01-home.png"
        with Image.open(output_path) as output:
            self.assertEqual(output.size, (1284, 2778))
            self.assertEqual(output.mode, "RGB")
            self.assertNotEqual(output.getpixel((0, 0)), raw.getpixel((0, 0)))

    def test_compositor_crops_the_ipad_system_date_region_without_repainting(self):
        root, _, manifest_path = self.write_raw_fixture()
        width, height = 2064, 2752
        date_region_color = (3, 251, 7)
        app_region_color = (17, 29, 241)
        raw_path = root / "Raw" / "en" / "ipad" / "01-home.png"
        raw_path.parent.mkdir(parents=True)
        raw = Image.new("RGB", (width, height), app_region_color)
        date_region_height = int(height * 0.18)
        raw.paste(
            date_region_color,
            (0, 0, width, date_region_height),
        )
        raw.save(raw_path)

        compositor = self.load_compositor("calculator_screenshot_compose_ipad_crop")
        frame = next(
            frame for frame in self.make_valid_frames()
            if frame["locale"] == "en" and frame["platform"] == "ipad"
            and frame["filename"] == "01-home.png"
        )
        compositor.compose_frame(frame, root, crop_system_date=True)

        output_path = root / "Generated" / "en" / "ipad" / "01-home.png"
        ui_top = int(height * 0.18)
        with Image.open(output_path) as output:
            self.assertEqual(
                output.getpixel((width // 2, ui_top + 10)),
                app_region_color,
            )
            self.assertNotIn(date_region_color, output.getdata())

    def test_compositor_rejects_traversal_and_absolute_filenames(self):
        for unsafe_filename in ("../escaped.png", "/tmp/absolute.png"):
            with self.subTest(unsafe_filename=unsafe_filename):
                root, frames, manifest_path = self.write_raw_fixture()
                frames[0]["filename"] = unsafe_filename
                manifest_path.write_text(
                    json.dumps({
                        "schemaVersion": 2,
                        "captureEnvironment": self.capture_environment(),
                        "frames": frames,
                    }),
                    encoding="utf-8",
                )
                compositor = self.load_compositor("calculator_screenshot_compose_unsafe")
                with self.assertRaisesRegex(ValueError, "safe path component"):
                    compositor.compose_manifest(manifest_path)

    def test_compositor_rejects_symlinked_generated_locale_or_platform_parent(self):
        for component in ("Generated", "locale", "platform"):
            with self.subTest(component=component):
                root, _, manifest_path = self.write_raw_fixture()
                if component == "Generated":
                    link = root / "Generated"
                    target = root / "safe-generated"
                elif component == "locale":
                    (root / "Generated").mkdir()
                    link = root / "Generated" / "zh-Hant"
                    target = root / "safe-locale"
                else:
                    (root / "Generated" / "zh-Hant").mkdir(parents=True)
                    link = root / "Generated" / "zh-Hant" / "iphone"
                    target = root / "safe-platform"
                target.mkdir()
                link.symlink_to(target, target_is_directory=True)
                compositor = self.load_compositor(
                    f"calculator_screenshot_compose_{component}_symlink"
                )
                self.write_raw_image(root, self.make_valid_frames()[0])
                with self.assertRaisesRegex(ValueError, "symlinked (generated root|output parent)"):
                    compositor.compose_frame(
                        self.make_valid_frames()[0],
                        root,
                        crop_system_date=True,
                    )

    def test_compositor_rejects_a_raw_root_symlink_outside_manifest_root(self):
        root, frames, _ = self.write_raw_fixture()
        frame = frames[0]
        outside_root = Path(tempfile.mkdtemp(prefix="outside-raw-root-"))
        self.addCleanup(shutil.rmtree, outside_root, ignore_errors=True)
        outside = outside_root / "Raw"
        (outside / frame["locale"] / frame["platform"]).mkdir(parents=True)
        Image.new("RGB", (frame["width"], frame["height"]), "white").save(
            outside / frame["locale"] / frame["platform"] / frame["filename"]
        )
        (root / "Raw").symlink_to(outside, target_is_directory=True)
        compositor = self.load_compositor("calculator_screenshot_compose_raw_root_symlink")
        with self.assertRaisesRegex(ValueError, "symlinked raw root"):
            compositor.compose_frame(frame, root, crop_system_date=True)

    def test_compositor_produces_identical_png_hashes_for_identical_inputs(self):
        root, frames, manifest_path = self.write_raw_fixture()
        compositor = self.load_compositor("calculator_screenshot_compose_deterministic")
        frame = next(
            frame for frame in frames
            if frame["locale"] == "en" and frame["platform"] == "iphone"
            and frame["filename"] == "01-home.png"
        )
        self.write_raw_image(root, frame)
        compositor.compose_frame(frame, root)

        def output_hashes():
            return hashlib.sha256(
                (root / "Generated" / "en" / "iphone" / "01-home.png").read_bytes()
            ).hexdigest()

        first_hashes = output_hashes()
        compositor.compose_frame(frame, root)
        self.assertEqual(output_hashes(), first_hashes)

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
