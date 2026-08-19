import socket
import unittest

def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    response = sock.recv(4096).decode('utf-8')
    return response

class TestCTE(unittest.TestCase):
    def test_cte_basic(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect(('127.0.0.1', 8080))
        
        send_query(sock, "CREATE TABLE cte_test (id INT, score INT);")
        send_query(sock, "INSERT INTO cte_test VALUES (1, 100);")
        send_query(sock, "INSERT INTO cte_test VALUES (2, 200);")
        send_query(sock, "INSERT INTO cte_test VALUES (3, 300);")
        
        q = "WITH my_cte AS (SELECT * FROM cte_test WHERE score > 150) SELECT * FROM my_cte;"
        r = send_query(sock, q)
        lines = r.strip().split('\n')
        
        self.assertEqual(len(lines), 3) # 2 rows + OK
        self.assertIn('2 | 200', lines[0])
        self.assertIn('3 | 300', lines[1])

        sock.close()

if __name__ == "__main__":
    unittest.main()
