from ..Classes import Pipe_Server
import time
from threading import Event
from pathlib import Path
from ..Classes import Log_Reader

# Test1.py - Testing Script
# Simple Key-Value Store Server. Tests pipe communication and logging with a key-value store.

def main(args: dict):
    '''
    Test server acting as a simple key-value store with log reading.

    Args:
    * args: Dictionary containing 'stop_event' (threading.Event) for shutdown.

    The server handles:
    - "write:[key]data" to store data
    - "read:[key]" to retrieve data
    - "close" to shut down
    '''
    # Initialize pipe server
    pipe = Pipe_Server('x4_pipe')
    pipe.Connect()

    # Initialize log reader (for demonstration, write to a temp log file)
    log_file = Path('test_log.txt')
    if not log_file.exists():
        log_file.touch()
    log_reader = Log_Reader(log_file)

    # Data store
    data_store = {}

    # Simulate logging by appending to the file
    def log_message(msg: str):
        with log_file.open('a') as f:
            f.write(f"{msg}\n")

    stop_event = args.get('stop_event', Event())
    while not stop_event.is_set():
        try:
            # Read from pipe
            message = pipe.Read()
            print(f"Received: {message}")
            log_message(f"Received: {message}")

            if message == 'close':
                break
            elif message.startswith('write:'):
                key, value = message[6:].split(']', 1)
                key = key[1:]
                data_store[key] = value
                log_message(f"Stored: {key} = {value}")
            elif message.startswith('read:'):
                key = message[5:-1]
                response = data_store.get(key, f"error: {key} not found")
                pipe.Write(response)
                log_message(f"Returned: {response}")
                print(f"Returned: {response}")

            # Check log reader (non-blocking with timeout)
            log_line = log_reader.readline(timeout=0.1)
            if log_line:
                print(f"Log Reader: {log_line}")

            # Trim log if too large
            log_reader.trim_log(max_size=1024)  # 1KB for testing

        except Exception as e:
            print(f"Error: {e}")
            log_message(f"Error: {e}")

    pipe.Close()
    print("Server stopped")

if __name__ == "__main__":
    main({'stop_event': Event()})