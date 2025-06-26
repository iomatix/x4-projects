import sys
import logging
import traceback
import signal
from .logging_utils import shutdown_logging

DEVELOPER_MODE = False

def signal_handler(sig, frame):
    """Handle termination signals and ensure logs are flushed."""
    logging.info(f"Received signal {sig}, shutting down...")
    shutdown_logging()
    sys.exit(0)

def exception_hook(exctype, value, tb):
    """Handle unhandled exceptions and ensure logs are flushed."""
    logging.error("Unhandled exception occurred:", exc_info=(exctype, value, tb))
    shutdown_logging()
    if DEVELOPER_MODE:
        traceback.print_exception(exctype, value, tb)
    sys.exit(1)