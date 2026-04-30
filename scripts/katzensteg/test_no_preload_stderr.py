import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class PreloadStderrTests(unittest.TestCase):
    def test_preload_and_layer_c_sources_do_not_write_to_stderr(self):
        offenders = []
        for path in (ROOT / "src" / "katzensteg").glob("*.c"):
            text = path.read_text()
            for token in ("fprintf(stderr", "vfprintf(stderr", "fputs(", "perror("):
                if token in text and "stderr" in text:
                    offenders.append(f"{path.relative_to(ROOT)} contains {token}")

        self.assertEqual([], offenders)


if __name__ == "__main__":
    unittest.main()
