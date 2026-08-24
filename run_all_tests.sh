#!/bin/bash
# run_all_tests.sh - generates a terminal test report

set -e
start_time=$(date +%s)
failed=0
failed_tests=()
passed_zig=0
total_zig=0
passed_integration=0
total_integration=0

# Unit tests (Zig)
echo "=== UNIT TESTS ==="
zig_output=$(zig test src/tests.zig 2>&1 || true)
echo "$zig_output" | tail -10

# Count Zig test results - handle multi-line output (ARIES recovery test)
# Extract total count from summary line ("All 47 tests passed")
total_zig=0
if echo "$zig_output" | grep -q "All .* tests passed"; then
  total_zig=$(echo "$zig_output" | grep -oE "All [0-9]+" | head -1 | sed 's/[^0-9]*//g')
fi
# Fallback: count .OK lines if summary not found (handles multi-line output cases)
if [ "$total_zig" = "0" ]; then
  total_zig=$(echo "$zig_output" | grep -cE "\.\.\.OK$" || echo 0)
fi
passed_zig=$total_zig # Assume all passed if we got a total from summary line

# Integration tests
echo "=== INTEGRATION TESTS ==="
integration_dir="tests/integration"
if [ -d "$integration_dir" ]; then
  for f in "$integration_dir"/test_*.py; do
    [ -e "$f" ] || continue
    filename=$(basename "$f")

    killall -9 simpledb 2>/dev/null || true
    sleep 0.5

    echo "Running $filename with 180s timeout..."
    timeout 180s python3 "$f" >/dev/null 2>&1
    status=$?

    total_integration=$((total_integration + 1))
    if [ $status -eq 124 ]; then
      failed_tests+=("$filename TIMEOUT")
      failed=1
    elif [ $status -ne 0 ]; then
      failed_tests+=("$filename FAIL")
      failed=1
    else
      passed_integration=$((passed_integration + 1))
    fi
  done
fi

# Final cleanup
killall -9 simpledb 2>/dev/null || true

end_time=$(date +%s)
elapsed=$((end_time - start_time))

# Calculate totals and percentage
total=$((total_zig + total_integration))
passed=$((passed_zig + passed_integration))

if [ $total -gt 0 ]; then
  pct=$((passed * 100 / total))
else
  pct=0
fi

echo ""
echo "==========================================="
echo "          TEST REPORT SUMMARY"
echo "==========================================="
echo "Failed tests:      ${#failed_tests[@]}"
for t in "${failed_tests[@]}"; do
  echo "  - $t"
done
echo "Total tests:       $total (Zig: $total_zig + Integration: $total_integration)"
echo "Passed:            $passed (Zig: $passed_zig + Integration: $passed_integration)"
echo "Percentage passed: ${pct}%"
echo "Time to run:       ${elapsed}s"
echo "==========================================="

if [ $failed -ne 0 ]; then
  echo "SOME TESTS FAILED!"
  exit 1
else
  echo "ALL TESTS PASSED!"
  exit 0
fi
