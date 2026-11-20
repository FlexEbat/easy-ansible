#!/usr/bin/env python3
"""Turn the interesting lines of an Ansible/verify log into GitHub annotations.

Used only by CI (on failure) so that the reason of a red job is visible in the
job summary without opening the raw log.
"""
import re
import sys

MAX = 900


def clean(text):
    return re.sub(r"\s+", " ", text).strip()[:MAX]


def main(paths):
    shown = 0
    for path in paths:
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        task = ""
        i = 0
        while i < len(lines) and shown < 25:
            line = lines[i]
            if line.startswith(("TASK [", "RUNNING HANDLER [")):
                task = line
            if re.match(r"^(fatal|changed|failed): ", line):
                block = [line]
                j = i + 1
                # A result can span several lines until the next blank line / TASK.
                while j < len(lines) and lines[j].strip() and not lines[j].startswith(("TASK [", "PLAY", "RUNNING HANDLER", "changed:", "ok:", "skipping:", "fatal:")):
                    block.append(lines[j])
                    j += 1
                print("::error title=%s::%s" % (clean(task)[:100], clean(" ".join(block))))
                shown += 1
                i = j
                continue
            if re.search(r"(?i)\b(fail|✗)\b|^\[FAIL\]|^FAIL", line) and "FAILED=0" not in line.upper():
                print("::error title=verify::%s" % clean(line))
                shown += 1
            if line.startswith("ERROR!") or "[ERROR]" in line:
                print("::error title=ansible::%s" % clean(" ".join(lines[i:i + 4])))
                shown += 1
            i += 1


if __name__ == "__main__":
    main(sys.argv[1:])
