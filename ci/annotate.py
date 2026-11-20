#!/usr/bin/env python3
"""Turn the interesting lines of CI logs into GitHub annotations.

Used only by CI (on failure) so that the reason of a red job is visible in the
job summary without opening the raw log. GitHub shows at most 10 annotations
per step, so the most important ones are printed first:
fatal errors, then verify failures, then tasks that changed on the second run.

usage: annotate.py first-run.log second-run.log verify.log
"""
import re
import sys

MAX = 800


def clean(text):
    return re.sub(r"\s+", " ", text).strip()[:MAX]


def read(path):
    try:
        return open(path, errors="replace").read().splitlines()
    except OSError:
        return []


def results(lines, kinds):
    """Yield (task, text) for result lines of the given kinds (fatal/changed/failed)."""
    task = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith(("TASK [", "RUNNING HANDLER [")):
            task = line.strip("* ").strip()
        m = re.match(r"^(%s): " % "|".join(kinds), line)
        if m:
            block = [line]
            j = i + 1
            while j < len(lines) and lines[j].strip() and not re.match(
                    r"^(TASK|PLAY|RUNNING HANDLER|changed:|ok:|skipping:|fatal:|failed:)", lines[j]):
                block.append(lines[j])
                j += 1
            yield task, " ".join(block)
            i = j
            continue
        i += 1


def main(first, second, verify):
    out = []
    for task, text in results(read(first), ["fatal", "failed"]):
        out.append(("first run", task + " :: " + text))
    for line in read(first):
        if line.startswith("ERROR!") or "[ERROR]" in line:
            out.append(("first run", line))
    for task, text in results(read(second), ["fatal", "failed"]):
        out.append(("second run", task + " :: " + text))
    for line in read(verify):
        if re.search(r"FAIL|✗", line):
            out.append(("verify", line))
    for task, text in results(read(second), ["changed"]):
        out.append(("second run changed", task + " :: " + text))
    for title, text in out[:9]:
        print("::error title=%s::%s" % (title, clean(text)))
    if len(out) > 9:
        print("::error title=more::%d more findings" % (len(out) - 9))


if __name__ == "__main__":
    args = sys.argv[1:] + [""] * 3
    main(*args[:3])
