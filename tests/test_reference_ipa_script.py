from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "download-reference-ipas.sh"


class ReferenceIPAScriptTests(unittest.TestCase):
    def test_script_has_valid_zsh_syntax(self) -> None:
        subprocess.run(["/bin/zsh", "-n", str(SCRIPT)], check=True)

    def test_script_never_accepts_or_passes_a_password(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("--password", source)
        self.assertNotIn("read -s", source)
        self.assertIn("ipatool auth login", source)

    def test_generated_ipas_live_outside_the_repository_by_default(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("$HOME/Library/Application Support/SpeakPaste/ReferenceIPAs", source)


if __name__ == "__main__":
    unittest.main()
