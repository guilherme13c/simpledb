#!/bin/bash
failed=0

echo "Running unit tests..."
mkdir -p data
zig build test || failed=1

echo "Running integration tests..."
for f in tests/integration/test_*.py; do
  # Kill any lingering simpledb from previous tests
  killall -9 simpledb 2>/dev/null
  sleep 0.5

  echo "Running $f with 180s timeout..."
  timeout 180s python3 "$f"
  status=$?

  if [ $status -eq 124 ]; then
    echo "$f TIMED OUT (>180s) - FAILED"
    failed=1
  elif [ $status -ne 0 ]; then
    echo "$f FAILED"
    failed=1
  else
    echo "$f PASSED"
  fi
done

# Final cleanup
killall -9 simpledb 2>/dev/null

if [ $failed -ne 0 ]; then
  echo "SOME TESTS FAILED!"
  exit 1
else
  echo "ALL TESTS PASSED!"
  exit 0
fi
