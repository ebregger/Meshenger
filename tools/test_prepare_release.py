import base64
from pathlib import Path
import tempfile
import unittest
from tools.prepare_release import java_property, release_tag, restore_signing

class PrepareReleaseTest(unittest.TestCase):
    def test_tags_must_match_the_apk_version(self):
        self.assertEqual(release_tag('version: 1.0.0+1\n'), 'v1.0.0')
        self.assertEqual(release_tag('version: 1.0.0-beta.1+2\n', 'v1.0.0-beta.1'), 'v1.0.0-beta.1')
        for version, tag in [('1.0.0+1', 'v0.1.0'), ('1.0.0+0', ''), ('1.0.0', '')]:
            with self.assertRaises(ValueError):
                release_tag(f'version: {version}\n', tag)
    def test_signing_restoration_refuses_overwrites(self):
        env = {'ANDROID_KEYSTORE_BASE64': base64.b64encode(b'test-key').decode(),
               'ANDROID_STORE_PASSWORD': 'password', 'ANDROID_KEY_PASSWORD': 'password',
               'ANDROID_KEY_ALIAS': 'upload'}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            restore_signing(root, env)
            self.assertEqual((root / 'android/app/upload-keystore.jks').read_bytes(), b'test-key')
            with self.assertRaises(ValueError):
                restore_signing(root, env)
    def test_missing_secrets_do_not_write_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                restore_signing(root, {})
            self.assertFalse((root / 'android').exists())
    def test_properties_preserve_special_password_characters(self):
        self.assertEqual(java_property(' a:b=c\\d\n'), '\\ a\\:b\\=c\\\\d\\n')
