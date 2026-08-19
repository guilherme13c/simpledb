import socket
import unittest
import time

def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    response = sock.recv(4096).decode('utf-8')
    return response

class TestWindow(unittest.TestCase):
    def test_window_basic(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        
        # Add retries for connection
        connected = False
        for _ in range(5):
            try:
                sock.connect(('127.0.0.1', 8080))
                connected = True
                break
            except ConnectionRefusedError:
                time.sleep(1)
        self.assertTrue(connected, "Failed to connect to SimpleDB")

        send_query(sock, "CREATE TABLE win_test_final (id INT, group_id INT, score INT);")
        send_query(sock, "INSERT INTO win_test_final VALUES (1, 1, 100);")
        send_query(sock, "INSERT INTO win_test_final VALUES (2, 1, 200);")
        send_query(sock, "INSERT INTO win_test_final VALUES (3, 2, 150);")
        send_query(sock, "INSERT INTO win_test_final VALUES (4, 2, 300);")
        
        # Test ROW_NUMBER() OVER(PARTITION BY group_id ORDER BY score DESC)
        q = "SELECT id, group_id, score, ROW_NUMBER() OVER(PARTITION BY group_id ORDER BY score DESC) FROM win_test_final;"
        r = send_query(sock, q)
        lines = r.strip().split('\n')
        
        self.assertEqual(len(lines), 5) # 4 rows + OK
        
        self.assertIn('2 | 1 | 200 | 1', lines[0])
        self.assertIn('1 | 1 | 100 | 2', lines[1])
        self.assertIn('4 | 2 | 300 | 1', lines[2])
        self.assertIn('3 | 2 | 150 | 2', lines[3])

        sock.close()

if __name__ == "__main__":
    unittest.main()
