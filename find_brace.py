lines = open('src/server/execution.zig').readlines()
level = 0
for i, line in enumerate(lines):
    for c in line:
        if c == '{': level += 1
        elif c == '}': level -= 1
    print(f"{i+1:4d} {level:2d} {line.rstrip()}")
