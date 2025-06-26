import logging
from logging.handlers import RotatingFileHandler, QueueHandler, QueueListener
from multiprocessing import Queue
import atexit

log_queue = Queue()
queue_listener = None

def setup_main_logging(log_file='X4_Python_Pipe_Server.log'):
    """Set up logging with file rotation and console fallback."""
    global queue_listener
    try:
        file_handler = RotatingFileHandler(
            log_file,
            maxBytes=5_000_000,
            backupCount=5
        )
        formatter = logging.Formatter('%(asctime)s | %(processName)s | %(levelname)s | %(message)s')
        file_handler.setFormatter(formatter)

        console_handler = logging.StreamHandler()
        console_handler.setFormatter(formatter)

        queue_listener = QueueListener(log_queue, file_handler, console_handler)
        queue_listener.start()

        root_logger = logging.getLogger()
        root_logger.setLevel(logging.DEBUG)
        root_logger.addHandler(QueueHandler(log_queue))

        atexit.register(shutdown_logging)

        return queue_listener
    except Exception as e:
        print(f"Failed to set up logging: {e}")
        logging.basicConfig(level=logging.DEBUG, format='%(asctime)s | %(levelname)s | %(message)s')
        return None

def setup_worker_logging(log_queue):
    """Set up logging for worker processes."""
    logger = logging.getLogger()
    logger.setLevel(logging.DEBUG)
    logger.handlers = []
    logger.addHandler(QueueHandler(log_queue))

def shutdown_logging():
    """Ensure all logs are flushed and QueueListener is stopped."""
    global queue_listener
    if queue_listener:
        logging.info("Shutting down logging...")
        queue_listener.stop()
        queue_listener = None
    for handler in logging.getLogger().handlers:
        handler.flush()