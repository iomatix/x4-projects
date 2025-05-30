import sys
import json
import argparse
import traceback
import logging
from pathlib import Path
from importlib import machinery
import win32api
import winerror
from multiprocessing import Process, Event
import inspect
from typing import List, Optional, Dict, Callable
from X4_Python_Pipe_Server.Classes import Pipe_Server, Pipe_Client, Client_Garbage_Collected

# Main.py - Core
# Manages the server lifecycle, including pipe setup, module loading, and process management.

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Version and constants
VERSION = '2.1.0'
PIPE_NAME = 'x4_python_host'
DEVELOPER_MODE = False  # Extra exception details for developers

# Permissions storage
permissions: Optional[Dict[str, bool]] = None
if getattr(sys, 'frozen', False):
    permissions_path = Path(sys.executable).parent / 'permissions.json'
else:
    permissions_path = Path(__file__).resolve().parent / 'permissions.json'

class Server_Process(Process):
    """A process wrapper for running module main functions with graceful shutdown."""
    def __init__(self, target: Callable, name: Optional[str] = None):
        self.stop_event = Event()
        self.target = target
        super().__init__(target=self.run_with_stop, name=name)
        self.daemon = True

    def run_with_stop(self) -> None:
        """Execute the target function, passing stop_event if supported."""
        sig = inspect.signature(self.target)
        if len(sig.parameters) >= 1:
            self.target(self.stop_event)
        else:
            self.target()

    def Close(self) -> None:
        """Signal the process to stop gracefully."""
        self.stop_event.set()

    def Join(self, timeout: float = 5.0) -> None:
        """Wait for the process to terminate, with a timeout and forced termination if needed."""
        self.join(timeout)
        if self.is_alive():
            logging.warning(f"Process {self.name} did not terminate in time; terminating forcefully")
            self.terminate()

def setup_paths() -> None:
    """Set up sys.path for package inclusion."""
    if not getattr(sys, 'frozen', False):
            home_path = Path(__file__).resolve().parents[1]
            if str(home_path) not in sys.path:
                sys.path.append(str(home_path))

def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description='Host pipe server for X4 interprocess communication.'
    )
    parser.add_argument('-p', '--permissions-path', help='Path to permissions.json.')
    parser.add_argument('-t', '--test', action='store_true', help='Enable test mode.')
    parser.add_argument('-x', '--x4-path', help='X4 installation path (test mode).')
    parser.add_argument('-m', '--module', help='Module path (test mode).')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output.')
    parser.add_argument('--no-restart', action='store_true', help='Disable auto-restart.')
    args = parser.parse_args()
    
    if args.test and (not args.x4_path or not args.module):
        logging.error("Test mode requires --x4-path and --module.")
        sys.exit(1)
    return args

def load_permissions(args: argparse.Namespace) -> None:
    """Load or generate the permissions file."""
    global permissions, permissions_path
    if args.permissions_path:
        permissions_path = Path(args.permissions_path).resolve()
    if permissions_path.exists():
        try:
            with permissions_path.open('r') as f:
                permissions = json.load(f)
            logging.info(f"Loaded permissions from {permissions_path}")
        except json.JSONDecodeError as e:
            logging.error(f"Failed to parse permissions: {e}")
    if not permissions:
        permissions = {
            'instructions': 'Set allowed extension IDs or folder names. IDs take precedence.',
            'ws_2042901274': True  # Modding API ID
        }
        with permissions_path.open('w') as f:
            json.dump(permissions, f, indent=2)
        logging.info(f"Created default permissions at {permissions_path}")

def check_permission(x4_path: Path, module_path: Path) -> bool:
    """Verify module permission using extension ID or folder name."""
    try:
        if not module_path.as_posix().startswith('extensions/'):
            raise ValueError("Module not in extensions directory")
        ext_dir = x4_path / module_path.parents[-3]
        folder_name = ext_dir.name
        content = (ext_dir / 'content.xml').read_text()
        ext_id = content.split('id="')[1].split('"')[0]
        
        # Check by ID first
        if ext_id in permissions and permissions[ext_id]:
            return True
        # Fallback to folder name
        elif folder_name in permissions and permissions[folder_name]:
            return True
        logging.warning(f"Module {module_path} (ID: {ext_id}, Folder: {folder_name}) lacks permission")
        return False
    except (FileNotFoundError, IndexError, ValueError) as e:
        logging.error(f"Permission check failed for {module_path}: {e}")
        return False

def import_module(path: Path):
    """Import a Python module from the given path."""
    try:
        module_name = f"user_module_{path.name.replace(' ', '_')}"
        module = machinery.SourceFileLoader(module_name, str(path)).load_module()
        logging.info(f"Imported module {path}")
        return module
    except ImportError as e:
        logging.error(f"Import failed for {path}: {e}")
        if DEVELOPER_MODE:
            logging.error(traceback.format_exc())
        return None

def run_server(args: argparse.Namespace) -> None:
    """Run the main server loop, managing module processes."""
    processes: List[Server_Process] = []
    module_relpaths: List[Path] = []
    shutdown = False

    while not shutdown:
        pipe = None
        try:
            pipe = Pipe_Server(PIPE_NAME, verbose=args.verbose)
            if args.test:
                threading.Thread(target=pipe_client_test, args=(args,)).start()
            pipe.Connect()
            x4_path: Optional[Path] = None

            while True:
                message = pipe.Read()
                logging.info(f"Received: {message}")

                if message == 'ping':
                    continue
                elif message == 'restart':
                    break
                elif message.startswith('package.path:'):
                    paths = [Path(p) for p in message[13:].split(';')]
                    for p in paths:
                        test_path = p
                        while test_path.parents:
                            if test_path.parent.name == 'lua':
                                x4_path = test_path.parent
                                break
                            test_path = test_path.parent
                elif message.startswith('modules:') and x4_path:
                    module_paths = [Path(p) for p in message[8:].split(';')[:-1]]
                    for mp in module_paths:
                        if mp in module_relpaths:
                            continue
                        full_path = x4_path / mp
                        if not check_permission(x4_path, mp):
                            continue
                        module_relpaths.append(mp)
                        module = import_module(full_path)
                        if module and hasattr(module, 'main'):
                            main_func = module.main
                            process_name = f"Process_{mp.as_posix().replace('/', '_')}"
                            if len(inspect.signature(main_func).parameters) >= 1:
                                process = Server_Process(target=main_func, name=process_name)
                                logging.info(f"Module {mp} supports graceful shutdown")
                            else:
                                def wrapper(stop_event: Event) -> None:
                                    main_func()
                                process = Server_Process(target=wrapper, name=process_name)
                                logging.warning(f"Module {mp} does not support graceful shutdown")
                            processes.append(process)
                            process.start()

        except (win32api.error, Client_Garbage_Collected) as e:
            if args.test:
                shutdown = True
                logging.info("Test mode completed")
            elif isinstance(e, Client_Garbage_Collected):
                logging.info("Client garbage collected")
            elif e.funcname == 'CreateNamedPipe':
                logging.error("Pipe creation failed; another instance running?")
                shutdown = True
            elif e.winerror == winerror.ERROR_BROKEN_PIPE:
                logging.info("Client disconnected")
            else:
                logging.error(f"Win32 error: {e.winerror} in {e.funcname}: {e.strerror}")
                shutdown = True
            if shutdown:
                input("Press Enter to exit...")
            elif not args.no_restart:
                logging.info("Restarting server")
            else:
                shutdown = True
        except KeyboardInterrupt:
            logging.info("Interrupted by user")
            shutdown = True
        except Exception as e:
            logging.error(f"Unexpected error: {e}")
            raise
        finally:
            if pipe:
                try:
                    pipe.Close()
                except Exception:
                    pass
            if shutdown:
                for p in processes:
                    p.Close()
                for p in processes:
                    p.Join()

def pipe_client_test(args: argparse.Namespace) -> None:
    """Simulate X4 client for testing."""
    pipe = Pipe_Client(PIPE_NAME)
    package_path = f".\\?.lua;{args.x4_path}\\lua\\?.lua;{args.x4_path}\\lua\\?\\init.lua;"
    pipe.Write(f"package.path:{package_path}")
    pipe.Write(f"modules:{args.module.as_posix()};")
    pipe.Read()

def main() -> None:
    """Entry point for the server."""
    setup_paths()
    args = parse_args()
    load_permissions(args)
    run_server(args)

if __name__ == '__main__':
    main()