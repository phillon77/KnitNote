#!/usr/bin/env python3
"""Calculator 1.2.0 (5): source preparation and separately gated release audit."""
import argparse
import hashlib
import os
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from knitting_calculator_release_source_check import strip_swift_comments_and_strings, verify_rating_storekit_surface

BUNDLE = 'com.phillon.KnittingCalculator'
APP_ID = 'ca-app-pub-2353011769485623~3090056510'
BANNER_ID = 'ca-app-pub-2353011769485623/1883207041'
POLICY = 'https://phillon77.github.io/knitting-calculator-ads-privacy.html'
REMOTES = {
    'GoogleMobileAds': ('https://github.com/googleads/swift-package-manager-google-mobile-ads.git', '13.9.0'),
    'GoogleUserMessagingPlatform': ('https://github.com/googleads/swift-package-manager-google-user-messaging-platform.git', '3.1.0'),
}
LOCALS = {'KnittingCalculatorCore', 'ShortRowKit'}
GATES = ('admob_account', 'admob_app', 'app_ads_txt', 'banner_video_and_refresh_disabled', 'publisher_consent_refuse_accept_withdraw', 'iphone_acceptance', 'ipad_acceptance', 'privacy_policy_live', 'app_store_privacy_review', 'release_tests')
FORBIDDEN = r'\b(?:\w*(?:Interstitial|Rewarded|AppOpen)\w*|ATTrackingManager|AppTrackingTransparency|URLSession|NWConnection|Network|Alamofire|AsyncHTTPClient|Firebase\w*|Mixpanel|Amplitude|Telemetry|Sentry|Adjust|AppsFlyer|Segment|StoreKit|RevenueCat|Adapty|Paddle)\b|\b(?:purchase|subscription)\s*\('

def tree_digest(root):
    """Hash sorted relative paths, types, modes and full bytes; never timestamps."""
    digest = hashlib.sha256()
    for path in sorted(root.rglob('*'), key=lambda p: p.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            if not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('bundle symlink escapes digest root: '+relative)
            kind, payload = 'link', os.readlink(path).encode()
        elif path.is_file():
            kind, payload = 'file', path.read_bytes()
        elif path.is_dir():
            kind, payload = 'directory', b''
        else:
            raise ValueError('unsupported digest entry: '+relative)
        header = json.dumps([relative, kind, path.lstat().st_mode & 0o777, len(payload)], separators=(',', ':')).encode()
        digest.update(len(header).to_bytes(8, 'big'))
        digest.update(header)
        digest.update(payload)
    return digest.hexdigest()


def source_digest(root):
    """Manifest-bound source, including uncommitted changes; excludes docs/builds."""
    files = set()
    for relative in ('KnittingCalculator', 'Packages/KnittingCalculatorCore', 'Packages/ShortRowKit'):
        files.update(p for p in (root/relative).rglob('*') if p.is_file() and not any(part in ('.build', '.git', '.swiftpm') for part in p.relative_to(root).parts))
    files.add(root/'KnittingCalculator.xcodeproj/project.pbxproj')
    files.add(root/'KnittingCalculator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
    digest = hashlib.sha256()
    for path in sorted(files, key=lambda p: p.relative_to(root).as_posix()):
        payload = path.read_bytes()
        header = json.dumps([path.relative_to(root).as_posix(), len(payload)], separators=(',', ':')).encode()
        digest.update(len(header).to_bytes(8, 'big'))
        digest.update(header)
        digest.update(payload)
    return digest.hexdigest()


def check_candidate(evidence, revision, archive_sha256, source_sha256):
    expected = {'source_revision': revision, 'archive_sha256': archive_sha256, 'source_sha256': source_sha256}
    return ['candidate evidence mismatch: '+key for key, value in expected.items() if not value or evidence.get(key) != value]


def check_pins(pins):
    actual = [(p.get('location'), p.get('state', {}).get('version')) for p in pins]
    return [] if sorted(actual, key=str) == sorted(REMOTES.values()) else ['resolved SDK allowlist/version mismatch']

def check_readiness(flag, evidence):
    errors = []
    if flag not in ('YES', True): errors.append('CALCULATOR_ADS_READY must be YES for release')
    if (evidence.get('version'), str(evidence.get('build'))) != ('1.2.0', '5'): errors.append('readiness evidence must identify 1.2.0 (5)')
    for gate in GATES:
        record = evidence.get('gates', {}).get(gate, {})
        if record.get('accepted') is not True or not str(record.get('evidence', '')).strip(): errors.append('missing accepted evidence: ' + gate)
    return errors

def check_swift(source, name):
    if name == 'KnittingCalculator/Model/RatingEligibility.swift': return []
    clean = strip_swift_comments_and_strings(source)
    match = re.search(FORBIDDEN, clean)
    errors = [name + ': prohibited API ' + match.group()] if match else []
    # These options are string-key SDK switches and must also be inspected literally.
    if re.search(r'"(?:collapsible|gad_has_consent_for_cookies)"', source): errors.append(name + ': unapproved ad option')
    return errors

def check_info(info):
    expected = {'CFBundleIdentifier':BUNDLE, 'CFBundleShortVersionString':'1.2.0', 'CFBundleVersion':'5', 'GADApplicationIdentifier':APP_ID, 'CalculatorBannerAdUnitID':BANNER_ID, 'GADDelayAppMeasurementInit':True}
    errors = ['archive Info.plist mismatch: '+key for key, value in expected.items() if info.get(key) != value]
    if 'NSUserTrackingUsageDescription' in info: errors.append('ATT permission description prohibited')
    return errors

def command(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)

def source_check(root):
    errors = []
    spec = json.loads(command('xcodegen', 'dump', '--spec', str(root/'KnittingCalculator/project.yml'), '--project-root', str(root), '--type', 'parsed-json'))
    packages = spec['packages']
    if set(packages) != set(REMOTES) | LOCALS: errors.append('project package allowlist mismatch')
    for name, (url, version) in REMOTES.items():
        package = packages.get(name, {})
        actual_url = package.get('url') or 'https://github.com/' + package.get('github', '')
        if actual_url != url or package.get('exactVersion') != version: errors.append('project SDK pin mismatch: '+name)
    for name in LOCALS:
        if packages.get(name, {}).get('path') != 'Packages/'+name: errors.append('local package mismatch: '+name)
        manifest = (root/'Packages'/name/'Package.swift').read_text()
        clean = strip_swift_comments_and_strings(manifest)
        if re.search(r'\.\s*(?:package|binaryTarget)\s*\(|\.dynamic\b', clean): errors.append('unapproved transitive dependency: '+name)
    if set(spec['targets']) != {'KnittingCalculator', 'KnittingCalculatorTests'}: errors.append('unexpected target')
    target = spec['targets']['KnittingCalculator']
    if sorted(d.get('package', '') for d in target['dependencies']) != sorted(set(REMOTES)|LOCALS): errors.append('linked package product mismatch')
    settings = target['settings']
    release = dict(settings.get('base', settings))
    release.update(settings.get('configs', {}).get('Release', {}))
    for key, value in {'MARKETING_VERSION':'1.2.0', 'CURRENT_PROJECT_VERSION':'5', 'PRODUCT_BUNDLE_IDENTIFIER':BUNDLE, 'CALCULATOR_ADMOB_APP_ID':APP_ID, 'CALCULATOR_BANNER_ID':BANNER_ID}.items():
        if str(release.get(key)) != value: errors.append('Release setting mismatch: '+key)
    pbx = json.loads(command('plutil', '-convert', 'json', '-o', '-', str(root/'KnittingCalculator.xcodeproj/project.pbxproj')))
    objects = list(pbx['objects'].values())
    remote_objects = [o for o in objects if o.get('isa') == 'XCRemoteSwiftPackageReference']
    errors += check_pins([{'location':o.get('repositoryURL'), 'state':{'version':o.get('requirement',{}).get('version')}} for o in remote_objects])
    if any(o.get('requirement',{}).get('kind') != 'exactVersion' for o in remote_objects): errors.append('generated SDK requirement must be exactVersion')
    local_paths = [o.get('relativePath') for o in objects if o.get('isa') == 'XCLocalSwiftPackageReference']
    if sorted(local_paths) != sorted('Packages/'+n for n in LOCALS): errors.append('generated local package mismatch')
    for o in objects:
        s = o.get('buildSettings', {})
        if 'MARKETING_VERSION' in s and (s['MARKETING_VERSION'], str(s.get('CURRENT_PROJECT_VERSION'))) != ('1.2.0','5'): errors.append('generated version/build mismatch')
        if o.get('name') == 'Release' and 'CALCULATOR_ADMOB_APP_ID' in s:
            for key in ('CALCULATOR_ADMOB_APP_ID','CALCULATOR_BANNER_ID','CALCULATOR_ADS_READY'):
                if s.get(key) != release.get(key): errors.append('generated Release mismatch: '+key)
    resolved = root/'KnittingCalculator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    errors += check_pins(json.loads(resolved.read_text())['pins'])
    for base in ['KnittingCalculator'] + ['Packages/'+n+'/Sources' for n in sorted(LOCALS)]:
        for path in (root/base).rglob('*.swift'):
            errors += check_swift(path.read_text(), str(path.relative_to(root)))
        if any((root/base).rglob('*.framework')) or any((root/base).rglob('*.xcframework')): errors.append('vendored framework prohibited: '+base)
    if not verify_rating_storekit_surface(root/'KnittingCalculator/Model/RatingEligibility.swift'): errors.append('rating StoreKit exception changed')
    settings_source = (root/'KnittingCalculator/Settings/CalculatorSettingsView.swift').read_text()
    if POLICY not in settings_source: errors.append('Settings advertising privacy URL missing')
    info = plistlib.loads((root/'KnittingCalculator/Info.plist').read_bytes())
    if info.get('GADDelayAppMeasurementInit') is not True or 'NSUserTrackingUsageDescription' in info: errors.append('source privacy configuration mismatch')
    return errors, release.get('CALCULATOR_ADS_READY')

def archive_check(root, archive):
    errors = []
    app = archive/'Products/Applications/KnittingCalculator.app'
    info = plistlib.loads((app/'Info.plist').read_bytes())
    errors += check_info(info)
    snapshots = json.loads((root/'AppStore/Advertising/SDKPrivacyManifests-2026-09-17.json').read_text())
    manifests = [plistlib.loads(p.read_bytes()) for p in app.rglob('PrivacyInfo.xcprivacy')]
    for sdk, manifest in snapshots.items():
        if manifest not in manifests: errors.append('missing or changed SDK privacy manifest: '+sdk)
    if not (app/'PrivacyInfo.xcprivacy').exists(): errors.append('missing app privacy manifest')
    command('codesign', '--verify', '--deep', '--strict', str(app))
    signing = subprocess.run(['codesign','-d','--verbose=4',str(app)], capture_output=True, text=True, check=True).stderr
    if 'TeamIdentifier=9CFPAUL5N5' not in signing or not re.search(r'^Authority=Apple Distribution:', signing, re.M): errors.append('archive must use expected Apple Distribution identity/team')
    profile = plistlib.loads(command('security','cms','-D','-i',str(app/'embedded.mobileprovision')))
    ent = profile.get('Entitlements', {})
    if ent.get('application-identifier') != '9CFPAUL5N5.'+BUNDLE or ent.get('get-task-allow') is not False or ent.get('beta-reports-active') is not True or 'ProvisionedDevices' in profile or 'ProvisionsAllDevices' in profile: errors.append('archive profile is not expected App Store distribution')
    executable = (app/info['CFBundleExecutable']).read_bytes()
    if POLICY.encode() not in executable: errors.append('archive advertising policy URL missing')
    if b'https://apps.apple.com/app/id6795877892' not in executable: errors.append('archive App Store identity missing')
    return errors, info.get('CalculatorAdsReady')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true', help='Source preparation only; never release certification')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--readiness', type=Path, help='Version-bound JSON acceptance evidence; see audit documentation')
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        errors, flag = source_check(root)
        revision = command('git', '-C', str(root), 'rev-parse', 'HEAD').decode().strip()
        source_sha256 = source_digest(root)
        print('source_revision='+revision)
        print('source_sha256='+source_sha256)
        archive_sha256 = None
        if args.archive:
            archive_sha256 = tree_digest(args.archive.resolve()/'Products/Applications/KnittingCalculator.app')
            print('archive_sha256='+archive_sha256)
            archive_errors, archive_flag = archive_check(args.root.resolve(), args.archive.resolve())
            errors += archive_errors
            if not args.prepare_only and archive_flag not in ('YES', True): errors.append('archive CalculatorAdsReady is disabled')
        if not args.prepare_only:
            if not args.archive: errors.append('final release requires --archive')
            evidence = json.loads(args.readiness.read_text()) if args.readiness else {}
            errors += check_readiness(flag, evidence)
            errors += check_candidate(evidence, revision, archive_sha256, source_sha256)
        if errors:
            for error in errors: print('FAIL: '+error, file=sys.stderr)
            return 1
        print('SOURCE PREPARATION PASS — not release readiness' if args.prepare_only else 'RELEASE AUDIT PASS — acceptance evidence supplied; submission remains separate')
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print('FAIL: '+str(error), file=sys.stderr)
        return 1

if __name__ == '__main__': sys.exit(main())
