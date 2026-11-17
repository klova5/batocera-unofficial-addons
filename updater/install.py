#!/usr/bin/env python3
"""Runs once after install_x86_new.sh installs or updates the BUA updater
package: applies the optional integrations it ships."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

nextendo = os.path.join(HERE, "integrations", "apply_switch_nextendo.py")
if os.path.isfile(nextendo):
    print("Checking Switch/Citron NexTendo integration...")
    if subprocess.call([sys.executable, nextendo]) != 0:
        print("Warning: NexTendo integration check failed.")
