import socket
import time
import statistics

def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    response = sock.recv(65536).decode('utf-8')
    return response

def setup_data(sock):
    send_query(sock, "DROP TABLE IF EXISTS employees;")
    send_query(sock, "DROP TABLE IF EXISTS departments;")
    
    send_query(sock, "CREATE TABLE departments (dept_id INT, dept_name VARCHAR);")
    send_query(sock, "CREATE TABLE employees (emp_id INT, dept_id INT, salary INT);")
    
    # Insert 10 departments
    for i in range(1, 11):
        send_query(sock, f"INSERT INTO departments VALUES ({i}, 'Dept{i}');")
        
    # Insert 500 employees (50 per department)
    for i in range(1, 501):
        dept_id = ((i - 1) % 10) + 1
        salary = 50000 + (i * 100)
        send_query(sock, f"INSERT INTO employees VALUES ({i}, {dept_id}, {salary});")

def run_benchmark(name, query, sock, iterations=5):
    times = []
    
    # Warmup
    send_query(sock, query)
    
    for _ in range(iterations):
        start = time.perf_counter()
        send_query(sock, query)
        end = time.perf_counter()
        times.append((end - start) * 1000) # ms
        
    avg = statistics.mean(times)
    p90 = statistics.quantiles(times, n=10)[8] if len(times) >= 2 else max(times)
    
    print(f"[{name}] Avg: {avg:.2f}ms | p90: {p90:.2f}ms")

if __name__ == "__main__":
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect(('127.0.0.1', 8080))
    
    print("Setting up benchmark data...")
    setup_data(sock)
    
    print("Running advanced SQL benchmarks...")
    
    run_benchmark(
        "Window Functions (ROW_NUMBER/PARTITION/ORDER)", 
        "SELECT emp_id, dept_id, salary, ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary DESC) FROM employees;",
        sock
    )
    
    run_benchmark(
        "Scalar Subquery", 
        "SELECT emp_id, dept_id, salary FROM employees WHERE salary > (SELECT 50000);",
        sock
    )
    
    run_benchmark(
        "In-Memory CTE", 
        "WITH high_earners AS (SELECT emp_id, dept_id FROM employees WHERE salary > 90000) SELECT emp_id, dept_id FROM high_earners;",
        sock
    )
    
    run_benchmark(
        "Outer Join (LEFT OUTER)", 
        "SELECT emp_id, dept_id, dept_name FROM employees LEFT OUTER JOIN departments ON dept_id = dept_id;",
        sock
    )
    
    sock.close()
