import sys
import json
import logging
import threading
from pathlib import Path
from importlib import machinery
import win32api
import winerror
from .logging_utils import setup_main_logging, shutdown_logging
from .handlers import signal_handler, exception_hook, DEVELOPER_MODE
from .server_process import Server_Process
from .config import parse_args, load_permissions, setup_paths, check_permission, permissions_path
from .Classes import Pipe_Server, Pipe_Client, Client_Garbage_Collected

VERSION = '2.2.0'
PIPE_NAME = 'x4_python_host'

logger = logging.getLogger(__name__)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)
sys.excepthook = exception_hook

def write_server_info(args):
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

def import_module(path):
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

def run_server(args):
    """Run the main server loop, managing module processes."""
    processes = []
    seen_modules = []
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

            x4_root = None

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
                shutdown_logging()

def handle_win32_exception(e, args):
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

def pipe_client_test(args):
    """Simulate X4 client for testing."""
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

def main():
    setup_paths()
    listener = setup_main_logging()
    args = parse_args()
    write_server_info(args)
    load_permissions(args)
    run_server(args)
    if listener:
        listener.stop()

if __name__ == '__main__':
    main()