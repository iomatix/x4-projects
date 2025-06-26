import sys
import json
import argparse
import logging
import traceback
import signal
from pathlib import Path
from importlib import machinery
import win32api
import winerror
from multiprocessing import Process, Event, Queue
import inspect
import threading
from typing import List, Optional, Dict, Callable
from logging.handlers import QueueHandler, QueueListener

from X4_Python_Pipe_Server.Classes import Pipe_Server, Pipe_Client, Client_Garbage_Collected

VERSION = '2.2.0'
PIPE_NAME = 'x4_python_host'

log_queue = Queue()

def setup_main_logging() -> QueueListener:
    """Configure main logging and start the queue listener."""
    handler = logging.StreamHandler()
    formatter = logging.Formatter('%(asctime)s | %(processName)s | %(levelname)s | %(message)s')
    handler.setFormatter(formatter)

    listener = QueueListener(log_queue, handler)
    listener.start()

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.DEBUG)
    root_logger.addHandler(QueueHandler(log_queue))
    return listener

def setup_worker_logging(queue: Queue = log_queue) -> None:
    """Configure logging for worker processes."""
    logger = logging.getLogger()
    logger.setLevel(logging.DEBUG)
    logger.addHandler(QueueHandler(queue))

def signal_handler(sig, frame):
    logging.info(f"Received signal {sig}, shutting down...")
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

log_format = '%(asctime)s %(levelname)s [%(threadName)s] %(message)s'
logging.basicConfig(level=logging.INFO, format=log_format)
logger = logging.getLogger(__name__)

DEVELOPER_MODE = False

if getattr(sys, 'frozen', False):
    permissions_path = Path(sys.executable).parent / 'permissions.json'
else:
    permissions_path = Path(__file__).resolve().parent / 'permissions.json'

permissions: Optional[Dict[str, bool]] = None

class Server_Process(Process):
    """Wraps a process to run a module's main function with graceful shutdown."""
    def __init__(self, target: Callable, name: Optional[str] = None):
        super().__init__(target=self.run_with_stop, name=name, daemon=True)
        self.stop_event = Event()
        self._target_fn = target

    def run_with_stop(self) -> None:
        sig = inspect.signature(self._target_fn)
        if len(sig.parameters) >= 1:
            logger.debug(f"{self.name}: calling target with stop_event")
            self._target_fn(self.stop_event)
        else:
            logger.debug(f"{self.name}: calling target without stop_event")
            self._target_fn()

    def Close(self) -> None:
        logger.info(f"{self.name}: signaling graceful shutdown")
        self.stop_event.set()

    def Join(self, timeout: float = 5.0) -> None:
        self.join(timeout)
        if self.is_alive():
            logger.warning(f"{self.name}: did not terminate in time; terminating forcefully")
            self.terminate()

def setup_paths() -> None:
    """Add parent directory to sys.path when not frozen."""
    if not getattr(sys, 'frozen', False):
        home_path = Path(__file__).resolve().parents[1]
        if str(home_path) not in sys.path:
            sys.path.append(str(home_path))

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description='Host pipe server for X4 interprocess communication.')
    parser.add_argument('-p', '--permissions-path', help='Path to permissions.json.')
    parser.add_argument('-t', '--test', action='store_true', help='Enable test mode.')
    parser.add_argument('-x', '--x4-path', help='X4 installation path (test mode).')
    parser.add_argument('-m', '--module', help='Module path (test mode).')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output.')
    parser.add_argument('--no-restart', action='store_true', help='Disable auto-restart.')
    args = parser.parse_args()

    if args.verbose:
        logger.setLevel(logging.DEBUG)
    if args.test and (not args.x4_path or not args.module):
        logger.error("Test mode requires both --x4-path and --module")
        sys.exit(1)
    return args

def write_server_info(args: argparse.Namespace) -> None:
    logger.info(f"Starting X4 Python Pipe Server v{VERSION}")
    logger.info(f"Running in {'frozen' if getattr(sys, 'frozen', False) else 'script'} mode")
    logger.info(f"Permissions file: {permissions_path}")
    if args.test:
        x4exe = Path(args.x4_path) / "X4.exe"
        if x4exe.exists():
            logger.info(f"Found X4.exe for test: {x4exe}")
        else:
            logger.warning(f"X4.exe not found at expected test path: {x4exe}")

def load_permissions(args: argparse.Namespace) -> None:
    global permissions, permissions_path
    if args.permissions_path:
        permissions_path = Path(args.permissions_path).resolve()

    if permissions_path.exists():
        try:
            permissions = json.loads(permissions_path.read_text())
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse permissions.json: {e}")
            permissions = None

    if not permissions:
        permissions = {'instructions': 'Set allowed extension IDs or folder names.', 'ws_2042901274': True}
        permissions_path.write_text(json.dumps(permissions, indent=2))

def check_permission(x4_path: Path, module_path: Path) -> bool:
    try:
        if not module_path.as_posix().startswith('extensions/'):
            raise ValueError("Module not in extensions directory")
        ext_dir = x4_path / module_path.parents[-3]
        content = (ext_dir / 'content.xml').read_text()
        ext_id = content.split('id="')[1].split('"')[0]
        folder = ext_dir.name
        return permissions.get(ext_id) or permissions.get(folder)
    except Exception as e:
        logger.error(f"Permission check error for {module_path}: {e}")
        return False

def import_module(path: Path):
    try:
        module_name = f"user_module_{path.name.replace(' ', '_')}"
        module = machinery.SourceFileLoader(module_name, str(path)).load_module()
        return module
    except Exception as e:
        logger.error(f"Failed to import module {path}: {e}")
        if DEVELOPER_MODE:
            logger.debug(traceback.format_exc())
        return None
