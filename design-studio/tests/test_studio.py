import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('studio', Path(__file__).parents[1] / 'studio.py')
assert spec is not None and spec.loader is not None
studio = importlib.util.module_from_spec(spec)
if Path(__file__).parents[1].joinpath('studio.py').exists(): spec.loader.exec_module(studio)

class KotlinTest(unittest.TestCase):
    def test_catalog_derives_alias_token_roles(self):
        component=next(c for c in studio.catalog()['components'] if c['name']=='SoundQButton')
        self.assertIn('SoundQ.colors.primary',component['token_roles'])
    def test_comments_strings_do_not_trigger_policy(self):
        self.assertEqual([], studio.adoption_errors('/* Button( Color(0xff) */ val s="TextField( Color.Red"; SoundQButton("ok", {})'))
    def test_stock_and_alias_are_rejected(self):
        self.assertTrue(studio.adoption_errors('import androidx.compose.material3.Button as B\n B(onClick={}) {}'))
        self.assertTrue(studio.adoption_errors('TextField(value="", onValueChange={})'))
    def test_color_rejected_not_layout_literals(self):
        self.assertTrue(studio.adoption_errors('val c=Color(0xff123456)'))
        self.assertEqual([], studio.adoption_errors('Spacer(Modifier.height(24.dp)); Text("hello", color=SoundQ.colors.text)'))

if __name__ == '__main__': unittest.main()
