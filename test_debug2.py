import socket
def send_query(sock, query):
    sock.sendall(query.encode('utf-8'))
    return sock.recv(4096).decode('utf-8')

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('127.0.0.1', 8080))
send_query(sock, "DROP TABLE IF EXISTS win_test2;")
print(send_query(sock, "CREATE TABLE win_test2 (id INT, group_id INT, score INT);"))
print(send_query(sock, "INSERT INTO win_test2 VALUES (1, 1, 100);"))
print(send_query(sock, "INSERT INTO win_test2 VALUES (2, 1, 200);"))
print(send_query(sock, "INSERT INTO win_test2 VALUES (3, 2, 150);"))
print(send_query(sock, "INSERT INTO win_test2 VALUES (4, 2, 300);"))

q = "SELECT id, group_id, score, ROW_NUMBER() OVER(PARTITION BY group_id ORDER BY score DESC) FROM win_test2;"
r = send_query(sock, q)
print(r)
sock.close()
