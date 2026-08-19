import socket
import time
import unittest

def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    response = sock.recv(4096).decode('utf-8')
    return response

class TestOuterJoin(unittest.TestCase):
    def test_left_join(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', 8080))
        
        queries = [
            "CREATE TABLE users_oj (id INT, name VARCHAR);",
            "CREATE TABLE orders_oj (id INT, user_id INT, total INT);",
            "INSERT INTO users_oj VALUES (1, 'alice');",
            "INSERT INTO users_oj VALUES (2, 'bob');",
            "INSERT INTO users_oj VALUES (3, 'charlie');",
            "INSERT INTO orders_oj VALUES (10, 1, 100);",
            "INSERT INTO orders_oj VALUES (11, 2, 200);",
            "INSERT INTO orders_oj VALUES (12, 1, 150);"
        ]
        
        for q in queries:
            send_query(sock, q)
            
        r = send_query(sock, "SELECT * FROM users_oj LEFT JOIN orders_oj ON id = user_id;")
        
        lines = r.strip().split('\n')
        # alice has 2 orders
        # bob has 1 order
        # charlie has 0 orders, should be padded with NULLs
        print(lines)
        self.assertEqual(len(lines), 4)
        
        charlie_line = [l for l in lines if 'charlie' in l][0]
        self.assertIn('NULL | NULL | NULL', charlie_line)

        sock.close()

if __name__ == "__main__":
    unittest.main()
