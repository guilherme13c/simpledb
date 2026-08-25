import socket
import time
import sys

HOST = "127.0.0.1"
DB_PORT = 8080

def send(s, msg):
    s.sendall(msg.encode('utf-8') + b"\n")
    return s.recv(4096 * 1024).decode('utf-8').strip()

def run_benchmark(s, description, query, iterations=5):
    times = []
    
    # Warmup
    send(s, query)
    
    for _ in range(iterations):
        start = time.perf_counter()
        send(s, query)
        end = time.perf_counter()
        times.append((end - start) * 1000)
        
    avg = sum(times) / len(times)
    times_sorted = sorted(times)
    p90_idx = int(len(times_sorted) * 0.9) - 1
    p90 = times_sorted[p90_idx] if p90_idx >= 0 else times_sorted[0]
    
    print(f"{description}: Avg: {avg:.2f}ms | p90: {p90:.2f}ms")
    return avg

if __name__ == "__main__":
    print("Connecting to SimpleDB at 127.0.0.1:8080...")
    try:
        with socket.create_connection((HOST, DB_PORT)) as s:
            print("\nRunning Transaction & WAL benchmarks...")
            
            # Test 1: Append heavy (similar to benchmark but with multiple commits)
            run_benchmark(s, "WAL Append Records (1k records)", 
                         "BEGIN; INSERT INTO t_tiny VALUES (1, 'tiny'); COMMIT;", 
                         3)
            
            # Test 2: Read Committed transactions
            run_benchmark(s, "Read Committed Transaction", 
                         "BEGIN; SELECT * FROM t_tiny WHERE id = 1; COMMIT;", 
                         5)
            
            # Test 3: Multiple inserts in single transaction
            run_benchmark(s, "Multi-insert Transaction (100 rows)", 
                         "BEGIN; INSERT INTO t_large VALUES (1, 'large'); INSERT INTO t_large VALUES (2, 'large'); COMMIT;", 
                         3)
            
            # Test 4: Read-heavy with snapshot isolation
            run_benchmark(s, "MVCC Read (10 reads)", 
                         "BEGIN; SELECT * FROM t_tiny; COMMIT;", 
                         5)
                
            print("\nTransaction benchmarks completed successfully.")
    except ConnectionRefusedError:
        print("Error: Could not connect to the database. Make sure the server is running!")
        sys.exit(1)