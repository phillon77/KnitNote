import importlib.util
import tempfile
import unittest
from pathlib import Path

from PIL import Image


VALIDATOR_PATH = Path(__file__).with_name("validate.py")
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

    def test_generated_image_must_be_opaque_rgb(self):
        root, frames = self.write_complete_fixture(mode="RGBA")
        with self.assertRaisesRegex(ValueError, "opaque RGB"):
            validate.validate_images(root, frames)


if __name__ == "__main__":
    unittest.main()
