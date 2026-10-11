import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "api-proxy" / "api_proxy.py"
SPEC = importlib.util.spec_from_file_location("api_proxy", MODULE_PATH)
api_proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(api_proxy)


class ModelAllowlistTests(unittest.TestCase):
    def setUp(self):
        self.original = api_proxy.ALLOWED_MODELS
        api_proxy.ALLOWED_MODELS = {"allowed-model"}

    def tearDown(self):
        api_proxy.ALLOWED_MODELS = self.original

    def test_allows_listed_model(self):
        self.assertIsNone(api_proxy.model_denial("allowed-model", True))

    def test_denies_unlisted_model(self):
        self.assertEqual(
            api_proxy.model_denial("other-model", True),
            "model 'other-model' not allowed",
        )

    def test_denies_missing_or_invalid_model(self):
        for model in (None, "", 123, ["allowed-model"]):
            with self.subTest(model=model):
                self.assertEqual(
                    api_proxy.model_denial(model, True),
                    "request must name an allowed model",
                )

    def test_allows_bodyless_discovery_request(self):
        self.assertIsNone(api_proxy.model_denial(None, False))

    def test_disabled_allowlist_allows_any_model(self):
        api_proxy.ALLOWED_MODELS = set()
        self.assertIsNone(api_proxy.model_denial("other-model", True))


if __name__ == "__main__":
    unittest.main()
