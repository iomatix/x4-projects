import sys
from pathlib import Path
import subprocess
import time
from threading import Event

# Add the root directory to sys.path
root_dir = Path(__file__).resolve().parents[2]  # Navigate up to X4_Python_Pipe_Server
sys.path.insert(0, str(root_dir))

# Absolute import
from X4_Python_Pipe_Server.Classes import Pipe_Client

def test_server():
    """
    Test the compiled X4_Python_Pipe_Server executable by simulating a client.
    Sends write, read, and close commands, verifying responses.
    """
    # Path to the compiled executable
    exe_path = Path(__file__).parent.parent / 'bin' / 'X4_Python_Pipe_Server.exe'
    if not exe_path.exists():
        print("Compiled executable not found at", exe_path)
        return

    # Start the server as a subprocess
    server_process = subprocess.Popen([str(exe_path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    print("Started server process:", server_process.pid)

    # Give the server a moment to start
    time.sleep(2)

    # Initialize the pipe client
    pipe = Pipe_Client('x4_python_host')  # Matches PIPE_NAME in Main.py
    pipe.Connect()

    # Test 1: Write a key-value pair
    print("Sending write command...")
    pipe.Write("write:[food]bard")
    time.sleep(0.5)

    # Test 2: Read the value back
    print("Sending read command...")
    pipe.Write("read:[food]")
    response = pipe.Read()
    print("Received:", response)
    if response != "bard":
        print("Test failed: Expected 'bard', got", response)
    else:
        print("Test passed: Successfully read 'bard'")

    # Test 3: Close the server
    print("Sending close command...")
    pipe.Write("close")
    time.sleep(1)

    # Verify server shutdown
    server_process.terminate()
    stdout, stderr = server_process.communicate(timeout=5)
    print("Server stdout:", stdout.decode())
    if stderr:
        print("Server stderr:", stderr.decode())

    pipe.Close()

if __name__ == "__main__":
    test_server()