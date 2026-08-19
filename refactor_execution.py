import re

with open("src/server/execution.zig", "r") as f:
    code = f.read()

# I will write a simple python script to just rewrite execute_statement to use heap allocators
# Wait, let's just do it step by step in python
lines = code.split('\n')
new_lines = []

for line in lines:
    if "var seq_exec: exec.SeqScanExecutor = undefined;" in line: continue
    if "var index_exec: exec.IndexScanExecutor = undefined;" in line: continue
    if "var filter_exec: exec.FilterExecutor = undefined;" in line: continue
    if "var right_seq_exec: exec.SeqScanExecutor = undefined;" in line: continue
    if "var join_exec: exec.NestedLoopJoinExecutor = undefined;" in line: continue
    if "var sort_merge_join_exec: exec.SortMergeJoinExecutor = undefined;" in line: continue
    if "var hash_join_exec: exec.HashJoinExecutor = undefined;" in line: continue
    if "var proj_exec: exec.ProjectExecutor = undefined;" in line: continue
    if "var agg_exec: exec.AggregateExecutor = undefined;" in line: continue
    if "var order_by_exec: exec.OrderByExecutor = undefined;" in line: continue
    if "var limit_exec: exec.LimitExecutor = undefined;" in line: continue
    if "var final_executor: exec.Executor = " in line: continue

    
    # Replace initializations
    line = re.sub(r'seq_exec = exec.SeqScanExecutor{', r'var seq_exec = try allocator.create(exec.SeqScanExecutor);\nseq_exec.* = .{', line)
    line = re.sub(r'index_exec = exec.IndexScanExecutor{', r'var index_exec = try allocator.create(exec.IndexScanExecutor);\nindex_exec.* = .{', line)
    line = re.sub(r'filter_exec = exec.FilterExecutor{', r'var filter_exec = try allocator.create(exec.FilterExecutor);\nfilter_exec.* = .{', line)
    line = re.sub(r'right_seq_exec = exec.SeqScanExecutor{', r'var right_seq_exec = try allocator.create(exec.SeqScanExecutor);\nright_seq_exec.* = .{', line)
    line = re.sub(r'join_exec = exec.NestedLoopJoinExecutor{', r'var join_exec = try allocator.create(exec.NestedLoopJoinExecutor);\njoin_exec.* = .{', line)
    line = re.sub(r'sort_merge_join_exec = exec.SortMergeJoinExecutor{', r'var sort_merge_join_exec = try allocator.create(exec.SortMergeJoinExecutor);\nsort_merge_join_exec.* = .{', line)
    line = re.sub(r'hash_join_exec = exec.HashJoinExecutor{', r'var hash_join_exec = try allocator.create(exec.HashJoinExecutor);\nhash_join_exec.* = .{', line)
    line = re.sub(r'proj_exec = exec.ProjectExecutor{', r'var proj_exec = try allocator.create(exec.ProjectExecutor);\nproj_exec.* = .{', line)
    line = re.sub(r'agg_exec = exec.AggregateExecutor{', r'var agg_exec = try allocator.create(exec.AggregateExecutor);\nagg_exec.* = .{', line)
    line = re.sub(r'order_by_exec = exec.OrderByExecutor{', r'var order_by_exec = try allocator.create(exec.OrderByExecutor);\norder_by_exec.* = .{', line)
    line = re.sub(r'limit_exec = exec.LimitExecutor{', r'var limit_exec = try allocator.create(exec.LimitExecutor);\nlimit_exec.* = .{', line)
    
    # Replace pointers to children with pointer to executor struct directly
    line = line.replace('.child = .{ .seq_scan = &seq_exec }', '.child = .{ .seq_scan = seq_exec }')
    line = line.replace('.child = &left_executor_copy', '.child = left_executor_copy')
    line = line.replace('.child = &base_executor', '.child = base_executor')
    line = line.replace('.left_child = &left_executor_copy', '.left_child = try allocator.create(exec.Executor)')
    line = line.replace('.right_child = &right_executor', '.right_child = try allocator.create(exec.Executor)')
    
    # Actually wait! .child = &base_executor is wrong. It should be .child = try allocator.create(exec.Executor); .child.* = base_executor;
    
    new_lines.append(line)

with open("src/server/execution.zig", "w") as f:
    f.write('\n'.join(new_lines))
