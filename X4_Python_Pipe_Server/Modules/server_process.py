from multiprocessing import Process, Event
import logging
import inspect
from .logging_utils import setup_worker_logging, log_queue

class Server_Process(Process):
    """A process wrapper for running module main functions with graceful shutdown."""
    def __init__(self, target, name=None):
        super().__init__(target=self.run_with_stop, name=name, daemon=True)
        self.stop_event = Event()
        self._target_fn = target

    def run_with_stop(self):
        setup_worker_logging(log_queue)
        sig = inspect.signature(self._target_fn)
        try:
            if len(sig.parameters) >= 1:
                logger = logging.getLogger(__name__)
                logger.debug(f"{self.name}: calling target with stop_event")
                self._target_fn(self.stop_event)
            else:
                logger = logging.getLogger(__name__)
                logger.debug(f"{self.name}: calling target without stop_event")
                self._target_fn()
        except Exception as e:
            logger = logging.getLogger(__name__)
            logger.error(f"Exception in {self.name}: {e}", exc_info=True)
            raise

    def Close(self):
        logger = logging.getLogger(__name__)
        logger.info(f"{self.name}: signaling graceful shutdown")
        self.stop_event.set()

    def Join(self, timeout=5.0):
        logger = logging.getLogger(__name__)
        self.join(timeout)
        if self.is_alive():
            logger.warning(f"{self.name}: did not terminate in time; terminating forcefully")
            self.terminate()