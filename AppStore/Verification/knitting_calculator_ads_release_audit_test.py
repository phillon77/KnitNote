"""Run with python3 -m unittest discover -s AppStore/Verification -p '*ads_release_audit_test.py'."""
import copy
import importlib.util
import pathlib
import tempfile
import shutil
import subprocess
import sys
import unittest

PATH = pathlib.Path(__file__).with_name('knitting_calculator_ads_release_audit.py')

class AuditTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(PATH.exists(), 'advertising audit must exist')
        spec = importlib.util.spec_from_file_location('ads_audit', PATH)
        self.audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.audit)

    def test_exact_dependency_allowlist(self):
        a = self.audit
        pins = [{'location': url, 'state': {'version': version}} for url, version in a.REMOTES.values()]
        self.assertEqual(a.check_pins(pins), [])
        for mutation in [pins + [{'location': 'https://evil.invalid/sdk', 'state': {'version': '1'}}], pins[:1], [dict(pins[0], state={'version':'14.0.0'}), pins[1]]]:
            self.assertTrue(a.check_pins(mutation))

    def test_release_requires_all_gates_and_enabled_flag(self):
        a = self.audit
        evidence = {'version':'1.2.0', 'build':'5', 'gates': {k: {'accepted':True, 'evidence':'verified record'} for k in a.GATES}}
        self.assertEqual(a.check_readiness('YES', evidence), [])
        self.assertTrue(a.check_readiness('NO', evidence))
        for key in a.GATES:
            changed = copy.deepcopy(evidence)
            del changed['gates'][key]
            self.assertTrue(a.check_readiness('YES', changed), key)
        evidence['build'] = '4'
        self.assertTrue(a.check_readiness('YES', evidence))

    def test_source_rejects_unsafe_apis_but_ignores_comments(self):
        for token in ['InterstitialAd', 'RewardedAd', 'AppOpenAd', 'ATTrackingManager', 'URLSession', 'NWConnection', 'FirebaseAnalytics', 'StoreKit', 'RevenueCat']:
            self.assertTrue(self.audit.check_swift('import '+token, 'Other.swift'), token)
            self.assertEqual(self.audit.check_swift('// import '+token, 'Other.swift'), [])

    def test_candidate_evidence_requires_exact_revision_and_bundle_digest(self):
        a = self.audit
        evidence = {'source_revision': 'a'*40, 'archive_sha256': 'b'*64, 'source_sha256': 'c'*64}
        self.assertEqual(a.check_candidate(evidence, 'a'*40, 'b'*64, 'c'*64), [])
        for key in evidence:
            wrong = dict(evidence, **{key: 'wrong'})
            self.assertTrue(a.check_candidate(wrong, 'a'*40, 'b'*64, 'c'*64))

    def test_bundle_digest_includes_resources_names_and_symlinks(self):
        a = self.audit
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root/'Executable').write_bytes(b'code')
            (root/'PrivacyInfo.xcprivacy').write_bytes(b'privacy1')
            first = a.tree_digest(root)
            self.assertEqual(first, a.tree_digest(root))
            (root/'PrivacyInfo.xcprivacy').write_bytes(b'privacy2')
            second = a.tree_digest(root)
            self.assertNotEqual(first, second)
            (root/'PrivacyInfo.xcprivacy').rename(root/'Renamed.xcprivacy')
            third = a.tree_digest(root)
            self.assertNotEqual(second, third)
            (root/'Link').symlink_to('Executable')
            self.assertNotEqual(third, a.tree_digest(root))

    def test_archive_identity_rejects_wrong_version_and_test_id(self):
        a = self.audit
        info = {'CFBundleIdentifier':a.BUNDLE, 'CFBundleShortVersionString':'1.2.0', 'CFBundleVersion':'5', 'GADApplicationIdentifier':a.APP_ID, 'CalculatorBannerAdUnitID':a.BANNER_ID, 'GADDelayAppMeasurementInit':True}
        self.assertEqual(a.check_info(info), [])
        for key, value in [('CFBundleVersion','4'), ('GADApplicationIdentifier','ca-app-pub-3940256099942544~1458002511'), ('NSUserTrackingUsageDescription','track')]:
            self.assertTrue(a.check_info(dict(info, **{key:value})))

class IntegrationTests(unittest.TestCase):
    def test_current_source_prepare_passes_but_release_is_blocked(self):
        prepared = subprocess.run([sys.executable, str(PATH), '--prepare-only'], capture_output=True, text=True)
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        self.assertIn('not release readiness', prepared.stdout)
        release = subprocess.run([sys.executable, str(PATH)], capture_output=True, text=True)
        self.assertNotEqual(release.returncode, 0)
        self.assertIn('final release requires --archive', release.stderr)
        self.assertIn('missing accepted evidence: publisher_consent_refuse_accept_withdraw', release.stderr)

    def test_source_mutations_are_rejected(self):
        root = PATH.parents[2]
        with tempfile.TemporaryDirectory() as directory:
            fixture = pathlib.Path(directory)
            subprocess.run(['git', 'init', str(fixture)], check=True, capture_output=True)
            subprocess.run(['git', '-C', str(fixture), '-c', 'user.name=Audit Fixture', '-c', 'user.email=audit@example.invalid', 'commit', '--allow-empty', '-m', 'fixture'], check=True, capture_output=True)
            for relative in ['KnittingCalculator', 'KnittingCalculator.xcodeproj', 'Packages/ShortRowKit', 'Packages/KnittingCalculatorCore']:
                shutil.copytree(root/relative, fixture/relative, ignore=shutil.ignore_patterns('.build', '.git'))
            mutations = [
                ('KnittingCalculator/project.yml', '13.9.0', '14.0.0', 'SDK pin mismatch'),
                ('KnittingCalculator/project.yml', 'MARKETING_VERSION: 1.2.0', 'MARKETING_VERSION: 1.1.0', 'MARKETING_VERSION'),
                ('Packages/ShortRowKit/Package.swift', 'targets: [', 'dependencies: [.package(url: "https://evil.invalid", from: "1.0.0")], targets: [', 'unapproved transitive dependency'),
            ]
            for relative, before, after, diagnostic in mutations:
                path = fixture/relative
                original = path.read_text()
                self.assertIn(before, original)
                path.write_text(original.replace(before, after, 1))
                result = subprocess.run([sys.executable, str(PATH), '--prepare-only', '--root', str(fixture)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
                path.write_text(original)

if __name__ == '__main__': unittest.main()
