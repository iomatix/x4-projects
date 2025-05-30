import threading
import logging
import win32api
import winerror
from .Misc import Client_Garbage_Collected

# Server_Thread.py - Thread Management
# Runs server logic in a thread with restart capabilities.

class Server_Thread(threading.Thread):
    '''
    Class to handle a single server thread.
    Runs a pipe server in a separate thread, restarting it if the X4 client pipe is closed.
    Supports clean shutdown via a stop_event.

    Attributes:
    * entry_function
      - The function which will set up a Pipe and service it.
      - This function should accept a dictionary with 'test' and 'stop_event' keys.
      - It should check the stop_event periodically to allow for clean shutdown.
    * test
      - Bool, if True then in test mode, and the server will not reboot on a disconnect.
    * stop_event
      - threading.Event object used to signal the thread to stop.
    '''
    def __init__(self, entry_function, test=False):
        super().__init__()
        self.entry_function = entry_function
        self.test = test
        self.stop_event = threading.Event()
        # Start the thread immediately, as this object is now the thread
        self.start()

    def run(self):
        '''
        Entry point for the thread.
        Runs the server's entry_function, restarting it whenever the X4 pipe is broken,
        unless the stop_event is set or in test mode.
        '''
        boot_server = True
        while boot_server and not self.stop_event.is_set():
            boot_server = False
            try:
                # Pass test mode and stop_event to the entry_function
                self.entry_function({'test': self.test, 'stop_event': self.stop_event})
            except (win32api.error, Client_Garbage_Collected) as ex:
                if self.test:
                    logging.info('Pipe client disconnected; stopping test.')
                elif isinstance(ex, Client_Garbage_Collected):
                    logging.info('Pipe client garbage collected, restarting server.')
                    boot_server = True
                elif ex.winerror == winerror.ERROR_BROKEN_PIPE:
                    logging.info('Pipe client disconnected, restarting server.')
                    boot_server = True

    def Close(self):
        '''
        Signal the thread to stop by setting the stop_event.
        The thread will exit the next time it checks the stop_event.
        '''
        self.stop_event.set()

    def Join(self, timeout=5.0):
        '''
        Wait for the thread to terminate, with a timeout.
        If the thread does not terminate within the timeout, log a warning.
        '''
        super().join(timeout)
        if self.is_alive():
            logging.warning(f"Thread {self.name} did not terminate within {timeout} seconds")