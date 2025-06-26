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
from multiprocessing import Process, Event
import inspect
import threading
from typing import List, Optional, Dict, Callable
from multiprocessing import Queue
from logging.handlers import QueueHandler, QueueListener

from X4_Python_Pipe_Server.Classes import Pipe_Server, Pipe_Client, Client_Garbage_Collected

# Main.py - Core
# Manages the server lifecycle, including pipe setup, module loading, and process management.

# Version and constants
VERSION = '2.2.0'
PIPE_NAME = 'x4_python_host'

log_queue = Queue()
def setup_main_logging():
    handler = logging.StreamHandler()
    formatter = logging.Formatter('%(asctime)s | %(processName)s | %(levelname)s | %(message)s')
    handler.setFormatter(formatter)

    listener = QueueListener(log_queue, handler)
    listener.start()

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.DEBUG)
    root_logger.addHandler(QueueHandler(log_queue))
    return listener

def setup_worker_logging(log_queue):
    logger = logging.getLogger()
    logger.setLevel(logging.DEBUG)
    logger.addHandler(QueueHandler(log_queue))

# Signal handling for graceful shutdown
def signal_handler(sig, frame):
    logging.info(f"Received signal {sig}, shutting down...")
    # Optionally set a shutdown flag or call cleanup
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

# Configure root logger
log_format = '%(asctime)s %(levelname)s [%(threadName)s] %(message)s'
logging.basicConfig(level=logging.INFO, format=log_format)
logger = logging.getLogger(__name__)

DEVELOPER_MODE = False  # Extra exception details for developers

# Determine where permissions.json lives
if getattr(sys, 'frozen', False):
    permissions_path = Path(sys.executable).parent / 'permissions.json'
else:
    permissions_path = Path(__file__).resolve().parent / 'permissions.json'

permissions: Optional[Dict[str, bool]] = None


class Server_Process(Process):
    """A process wrapper for running module main functions with graceful shutdown."""
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
    """Set up sys.path for package inclusion."""
    if not getattr(sys, 'frozen', False):
        home_path = Path(__file__).resolve().parents[1]
        if str(home_path) not in sys.path:
            sys.path.append(str(home_path))
            logger.debug(f"Added {home_path!r} to sys.path")


def parse_args() -> argparse.Namespace:
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

    # Set log level
    if args.verbose:
        logger.setLevel(logging.DEBUG)
        logger.debug("Verbose mode enabled")

    # Validate test-mode arguments
    if args.test:
        if not args.x4_path or not args.module:
            logger.error("Test mode requires both --x4-path and --module")
            sys.exit(1)
        logger.info(f"Test mode ON: X4 root = {args.x4_path}, module = {args.module}")

    return args


def write_server_info(args: argparse.Namespace) -> None:
    """Log server startup information."""
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
    """Load or generate the permissions file."""
    global permissions, permissions_path
    if args.permissions_path:
        permissions_path = Path(args.permissions_path).resolve()
        logger.debug(f"Overriding permissions path: {permissions_path}")

    if permissions_path.exists():
        try:
            permissions = json.loads(permissions_path.read_text())
            logger.info(f"Loaded permissions from {permissions_path}")
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse permissions.json: {e}")
            permissions = None

    if not permissions:
        permissions = {
            'instructions': 'Set allowed extension IDs or folder names. IDs take precedence.',
            'ws_2042901274': True  # Modding API ID
        }
        permissions_path.write_text(json.dumps(permissions, indent=2))
        logger.info(f"Initialized default permissions at {permissions_path}")


def check_permission(x4_path: Path, module_path: Path) -> bool:
    """Verify module permission using extension ID or folder name."""
    try:
        if not module_path.as_posix().startswith('extensions/'):
            raise ValueError("Module not in extensions directory")

        ext_dir = x4_path / module_path.parents[-3]
        content_xml = ext_dir / 'content.xml'
        logger.debug(f"Checking permissions in {content_xml}")
        content = content_xml.read_text()
        ext_id = content.split('id="')[1].split('"')[0]
        folder = ext_dir.name

        if permissions.get(ext_id):
            logger.debug(f"Permission granted by ID {ext_id}")
            return True
        if permissions.get(folder):
            logger.debug(f"Permission granted by folder name {folder}")
            return True

        logger.warning(f"Permission denied for module {module_path} (ID={ext_id}, folder={folder})")
        return False

    except Exception as e:
        logger.error(f"Permission check error for {module_path}: {e}")
        return False


def import_module(path: Path):
    """Import a Python module from the given path."""
    try:
        logger.debug(f"Loading module from {path}")
        module_name = f"user_module_{path.name.replace(' ', '_')}"
        module = machinery.SourceFileLoader(module_name, str(path)).load_module()
        logger.info(f"Imported module {path}")
        return module

    except Exception as e:
        logger.error(f"Failed to import module {path}: {e}")
        if DEVELOPER_MODE:
            logger.debug(traceback.format_exc())
        return None


def run_server(args: argparse.Namespace) -> None:
    """Run the main server loop, managing module processes."""
    processes: List[Server_Process] = []
    seen_modules: List[Path] = []
    shutdown = False

    while not shutdown:
        pipe = None
        try:
            logger.info("Creating Pipe_Server...")
            pipe = Pipe_Server(PIPE_NAME, verbose=args.verbose)
            if args.test:
                logger.debug("Spawning pipe_client_test thread")
                threading.Thread(target=pipe_client_test, args=(args,), daemon=True).start()

            logger.info("Connecting to pipe...")
            pipe.connect()
            logger.info("Pipe connected, awaiting messages")         

            x4_root: Optional[Path] = None

            # Message loop
            while True:
                msg = pipe.read()
                logger.debug(f"Received raw message: {msg!r}")

                if msg == 'ping':
                    logger.debug("Ping received")
                    continue
                if msg == 'restart':
                    logger.info("Restart command received")
                    break

                if msg.startswith('package.path:'):
                    raw = msg[len('package.path:'):]
                    segments = [seg for seg in raw.split(';') if seg]
                    logger.debug(f"Parsed package.path segments: {segments!r}")

                    # find x4 root by locating the 'lua' or 'ui' parent
                    for seg in segments:
                        p = Path(seg)
                        for parent in [p] + list(p.parents):
                            if parent.name.lower() in ('lua', 'ui'):
                                x4_root = parent.parent
                                logger.info(f"Determined X4 root: {x4_root}")
                                break
                        if x4_root:
                            break
                    if not x4_root:
                        logger.warning("Failed to determine X4 root from package.path")

                elif msg.startswith('modules:') and x4_root:
                    raw = msg[len('modules:'):]
                    rels = [r for r in raw.split(';') if r]
                    logger.info(f"Modules announced: {rels}")
                    for rel in rels:
                        rel_path = Path(rel)
                        if rel_path in seen_modules:
                            logger.debug(f"Skipping already-handled module: {rel_path}")
                            continue

                        full = x4_root / rel_path
                        logger.debug(f"Resolved module path: {full}")
                        if not full.exists():
                            logger.error(f"Module file not found: {full}")
                            continue

                        if not check_permission(x4_root, rel_path):
                            continue

                        seen_modules.append(rel_path)
                        mod = import_module(full)
                        if not mod or not hasattr(mod, 'main'):
                            logger.warning(f"No `.main()` in module {rel_path}")
                            continue

                        main_fn = mod.main
                        proc_name = f"Proc_{rel_path.as_posix().replace('/', '_')}"
                        proc = Server_Process(target=main_fn, name=proc_name)
                        processes.append(proc)
                        proc.start()
                        logger.info(f"Started process {proc_name} for module {rel_path}")

        except (win32api.error, Client_Garbage_Collected) as e:
            shutdown = handle_win32_exception(e, args)
        except KeyboardInterrupt:
            logger.info("KeyboardInterrupt received, shutting down")
            shutdown = True
        except Exception as e:
            logger.error(f"Unhandled exception in server loop: {e}")
            if DEVELOPER_MODE:
                logger.debug(traceback.format_exc())
            shutdown = True
        finally:
            if pipe:
                try:
                    pipe.close()
                except Exception:
                    pass
            if shutdown:
                for p in processes:
                    p.Close()
                for p in processes:
                    p.Join()


def handle_win32_exception(e, args) -> bool:
    """Centralize logging & decision for win32api.error and Client_Garbage_Collected."""
    if args.test:
        logger.info("Test mode complete, exiting")
        return True

    if isinstance(e, Client_Garbage_Collected):
        logger.info("Client garbage collected, restarting pipe")
        return False

    if getattr(e, 'funcname', None) == 'CreateNamedPipe':
        logger.error("Pipe creation failed (another instance running?)")
        return True

    if getattr(e, 'winerror', None) == winerror.ERROR_BROKEN_PIPE:
        logger.info("Broken pipe (client disconnected), waiting for reconnect")
        return False

    logger.error(f"Win32 error {e.winerror} in {e.funcname}: {e.strerror}")
    return True


def pipe_client_test(args: argparse.Namespace) -> None:
    """Simulate X4 client for testing."""
    from pathlib import Path

    x4_root = Path(args.x4_path)
    if not x4_root.exists():
        raise RuntimeError(f"Invalid X4 path for test: {x4_root}")

    segments = [
        ".\\?.lua",
        str(x4_root / "lua" / "?.lua"),
        str(x4_root / "lua" / "?" / "init.lua"),
        str(x4_root / "ui"  / "?.lua"),
        str(x4_root / "ui"  / "?" / "init.lua"),
    ]
    package_path = ';'.join(segments) + ';'
    logger.debug(f"pipe_client_test sending package.path: {package_path!r}")

    pipe = Pipe_Client(PIPE_NAME)
    pipe.write(f"package.path:{package_path}")
    pipe.write(f"modules:{Path(args.module).as_posix()};")
    pipe.read()


def main() -> None:
    setup_paths()
    args = parse_args()
    write_server_info(args)
    load_permissions(args)
    run_server(args)


if __name__ == '__main__':
    main()
