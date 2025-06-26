import logging
import time
import win32api
import win32file
import win32pipe
import win32security
import winerror
import win32con
import ntsecuritycon as con
from pywintypes import error as Win32Error
from typing import Optional
from .Misc import Client_Garbage_Collected


class Pipe:
    """
    Abstract base class for named pipe communication using unidirectional pairs:
    - `pipe_in`: inbound pipe for reading
    - `pipe_out`: outbound pipe for writing

    Shared diagnostics, logging, and read/write operations are implemented here.
    Subclasses must implement `connect()` (for clients) or `create()` (for servers), and `close()`.
    """

    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None):
        """
        Initialize pipe paths and shared state.

        :param pipe_name: Base name for the pipe (e.g. 'X4_Python_Pipe')
        :param buffer_size: Optional buffer size for pipe I/O
        """
        self.pipe_name = pipe_name
        self.pipe_in_path = f"\\\\.\\pipe\\{pipe_name}_in"
        self.pipe_out_path = f"\\\\.\\pipe\\{pipe_name}_out"
        self.buffer_size = buffer_size or 65536

        self.pipe_in = None
        self.pipe_out = None
        self.nowait_set = False

        self.diagnostics = {
            'reads': 0,
            'writes': 0,
            'last_read': None,
            'last_write': None,
            'last_error': None
        }

        self.logger = logging.getLogger(__name__)

    def read(self) -> Optional[str]:
        """
        Read a UTF-8 message from the input pipe.
        :return: The decoded message, or None in non-blocking mode with no data.
        """
        try:
            result, data = win32file.ReadFile(self.pipe_in, self.buffer_size)
            message = data.decode('utf-8')
            self.diagnostics['reads'] += 1
            self.diagnostics['last_read'] = time.time()

            self.logger.debug(f"Read from pipe: {message}")
            if message == 'garbage_collected':
                raise Client_Garbage_Collected()
            return message
        except Win32Error as ex:
            self.diagnostics['last_error'] = str(ex)
            if ex.winerror == winerror.ERROR_NO_DATA and self.nowait_set:
                return None
            self.logger.error(f"Read error: {ex}")
            raise

    def write(self, message: str) -> None:
        """
        Write a UTF-8 message to the output pipe.
        :param message: The message string to write.
        """
        try:
            win32file.WriteFile(self.pipe_out, message.encode('utf-8'))
            self.diagnostics['writes'] += 1
            self.diagnostics['last_write'] = time.time()
            self.logger.debug(f"Wrote to pipe: {message}")
            win32file.FlushFileBuffers(self.pipe_out)
        except Win32Error as ex:
            self.diagnostics['last_error'] = str(ex)
            self.logger.error(f"Write error: {ex}")
            raise

    def set_nonblocking(self) -> None:
        """
        Configure both pipes to non-blocking (PIPE_NOWAIT) mode.
        """
        if self.nowait_set:
            return

        for name, pipe in zip(('in', 'out'), (self.pipe_in, self.pipe_out)):
            if not pipe:
                self.logger.warning(f"{name} pipe not initialized.")
                continue
            try:
                win32pipe.SetNamedPipeHandleState(
                    pipe,
                    win32pipe.PIPE_READMODE_MESSAGE | win32pipe.PIPE_NOWAIT,
                    None,
                    None
                )
                self.logger.debug(f"{name} pipe set to non-blocking.")
            except Win32Error as e:
                self.diagnostics['last_error'] = str(e)
                self.logger.error(f"Failed to set {name} pipe to non-blocking: {e}")
                raise

        self.nowait_set = True

    def set_blocking(self) -> None:
        """
        Configure both pipes to blocking (PIPE_WAIT) mode.
        """
        for pipe in (self.pipe_in, self.pipe_out):
            if not pipe:
                continue
            win32pipe.SetNamedPipeHandleState(
                pipe,
                win32pipe.PIPE_READMODE_MESSAGE | win32pipe.PIPE_WAIT,
                None,
                None
            )
        self.nowait_set = False

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, tb):
        self.close()

    def close(self) -> None:
        """
        Must be implemented by subclasses. Closes handles.
        """
        raise NotImplementedError("Subclasses must implement close().")


class Pipe_Server(Pipe):
    """
    Named pipe server using unidirectional read/write pipes.
    """

    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None, verbose: bool = False):
        """
        Create named pipes and set up security attributes.

        :param pipe_name: Base name of the pipe
        :param buffer_size: Optional buffer size
        :param verbose: Enable additional logging
        """
        super().__init__(pipe_name, buffer_size)
        self.verbose = verbose
        sec_attr = self._create_security_attributes()

        try:
            self.pipe_in = win32pipe.CreateNamedPipe(
                self.pipe_in_path,
                win32con.PIPE_ACCESS_INBOUND,
                win32pipe.PIPE_TYPE_MESSAGE | win32pipe.PIPE_READMODE_MESSAGE | win32pipe.PIPE_WAIT,
                1, self.buffer_size, self.buffer_size, 0, sec_attr
            )
            self.pipe_out = win32pipe.CreateNamedPipe(
                self.pipe_out_path,
                win32con.PIPE_ACCESS_OUTBOUND,
                win32pipe.PIPE_TYPE_MESSAGE | win32pipe.PIPE_WAIT,
                1, self.buffer_size, self.buffer_size, 0, sec_attr
            )
        except Win32Error as ex:
            self.diagnostics['last_error'] = str(ex)
            self.logger.exception("Failed to create named pipes")
            raise

        self.logger.info(f"Pipe server created: {self.pipe_in_path}, {self.pipe_out_path}")

    def _create_security_attributes(self):
        """
        Create security attributes allowing current user full access.
        """
        try:
            sd = win32security.SECURITY_DESCRIPTOR()
            sd.Initialize()
            user, _, _ = win32security.LookupAccountName(None, win32api.GetUserName())
            dacl = win32security.ACL()
            dacl.AddAccessAllowedAce(win32security.ACL_REVISION, con.FILE_GENERIC_READ | con.FILE_GENERIC_WRITE, user)
            sd.SetSecurityDescriptorDacl(1, None, 0) # Allow everyone (SACL param) for now (TODO: try dacl later)
            sa = win32security.SECURITY_ATTRIBUTES()
            sa.SECURITY_DESCRIPTOR = sd
            return sa
        except Exception as e:
            self.logger.warning("Could not create secure DACL. Proceeding with default.")
            return None

    def connect(self) -> None:
        """
        Wait for client connections on both pipe ends.
        """
        for name, pipe in zip(('in', 'out'), (self.pipe_in, self.pipe_out)):
            try:
                self.logger.debug(f"Waiting for client to connect on {name} pipe...")
                if name == 'in':
                    self.logger.debug(f"... at {self.pipe_in_path}")
                elif name == 'out':
                    self.logger.debug(f"... at {self.pipe_out_path}")
                win32pipe.ConnectNamedPipe(pipe, None)
                self.logger.info(f"Client connected on {name} pipe.")
            except Win32Error as e:
                if e.winerror == winerror.ERROR_PIPE_CONNECTED:
                    self.logger.debug(f"Client already connected on {name}.")
                else:
                    self.logger.error(f"Error connecting to pipe {name}: {e}")
                    raise

    def close(self) -> None:
        """
        Disconnect and close both pipe handles.
        """
        self.logger.info("Closing server pipe handles.")
        for pipe in (self.pipe_in, self.pipe_out):
            if not pipe:
                continue
            try:
                win32file.FlushFileBuffers(pipe)
                win32pipe.DisconnectNamedPipe(pipe)
                win32file.CloseHandle(pipe)
            except Win32Error as e:
                self.logger.warning(f"Error closing pipe: {e}")


class Pipe_Client(Pipe):
    """
    Named pipe client using unidirectional read/write pipes.
    """

    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None):
        """
        Initialize paths and connect to server pipes.

        :param pipe_name: Base pipe name (same as server)
        :param buffer_size: Optional buffer size
        """
        super().__init__(pipe_name, buffer_size)

    def connect(self, timeout: float = 10.0, interval: float = 0.25) -> None:
        """
        Attempt to connect to the server pipes with retry.

        :param timeout: Max time in seconds to retry
        :param interval: Delay between attempts
        """
        deadline = time.time() + timeout

        while time.time() < deadline:
            try:
                self.pipe_out = win32file.CreateFile(
                    self.pipe_out_path,
                    win32con.GENERIC_WRITE,
                    0,
                    None,
                    win32con.OPEN_EXISTING,
                    0,
                    None
                )
                self.pipe_in = win32file.CreateFile(
                    self.pipe_in_path,
                    win32con.GENERIC_READ,
                    0,
                    None,
                    win32con.OPEN_EXISTING,
                    0,
                    None
                )
                self.logger.info("Connected to server pipes.")
                return
            except Win32Error as e:
                if e.winerror in (winerror.ERROR_FILE_NOT_FOUND, winerror.ERROR_PIPE_BUSY):
                    time.sleep(interval)
                else:
                    self.logger.error(f"Unexpected error connecting to pipes: {e}")
                    raise

        raise TimeoutError(f"Failed to connect to pipes within {timeout:.1f}s")

    def close(self) -> None:
        """
        Close pipe handles.
        """
        self.logger.info("Closing client pipe handles.")
        for pipe in (self.pipe_in, self.pipe_out):
            if pipe:
                try:
                    win32file.CloseHandle(pipe)
                except Win32Error as e:
                    self.logger.warning(f"Error closing client pipe: {e}")
