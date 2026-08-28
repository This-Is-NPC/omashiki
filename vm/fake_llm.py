#!/usr/bin/env python3
"""Run the repository's controlled fake provider from an installed source tree."""

from pathlib import Path
import runpy


runpy.run_path(str(Path(__file__).resolve().parents[1] / ".scripts" / "loadtest" / "fake_llm.py"), run_name="__main__")
