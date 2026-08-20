#!/bin/bash
failed=0

echo "Running unit tests..."
zig build test || failed=1

echo "Running integration tests..."
for f in tests/integration/test_*.py; do
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

if [ $failed -ne 0 ]; then
    echo "SOME TESTS FAILED!"
    exit 1
else
    echo "ALL TESTS PASSED!"
    exit 0
fi
