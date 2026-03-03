#!/usr/bin/env python3
"""Calculate ops/second rate from count and elapsed milliseconds."""

import sys


def main():
    if len(sys.argv) < 3:
        print("Usage: calc_rate.py <count> <elapsed_ms>", file=sys.stderr)
        sys.exit(1)

    count = int(sys.argv[1])
    elapsed_ms = int(sys.argv[2])

    if elapsed_ms <= 0:
        print("0")
    else:
        print(f"{count / (elapsed_ms / 1000):.0f}")


if __name__ == "__main__":
    main()
