#!/usr/bin/env python3
import os
import sys

EMOJI_RANGES = [
    (0x1F600, 0x1F64F),
    (0x1F300, 0x1F5FF),
    (0x1F680, 0x1F6FF),
    (0x2600, 0x26FF),
    (0x2700, 0x27BF),
    (0x1F900, 0x1F9FF),
    (0x1FA70, 0x1FAFF),
]


def has_emoji(line):
    for char in line:
        code = ord(char)
        for start, end in EMOJI_RANGES:
            if start <= code <= end:
                return True
    return False


def check_file(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            for line_num, line in enumerate(f, 1):
                if has_emoji(line):
                    return line_num
    except Exception:
        pass
    return None


def main():
    print("Checking for emojis in source code...")
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found_emojis = False

    for root, _, files in os.walk(base_dir):
        if any(x in root for x in [".build", ".git", "Pods", ".xcworkspace", ".xcodeproj", "DerivedData", "localPackages"]):
            continue
        for file in files:
            if not file.endswith((".swift", ".sh", ".py")):
                continue
            if file == "check_emojis.py":
                continue
            full_path = os.path.join(root, file)
            line_num = check_file(full_path)
            if line_num:
                print(f"Error: Emoji found in {os.path.relpath(full_path, base_dir)} at line {line_num}")
                found_emojis = True

    if found_emojis:
        print("Failure: Emojis are not allowed in the codebase.")
        sys.exit(1)
    else:
        print("Success: No emojis found.")
        sys.exit(0)


if __name__ == "__main__":
    main()
