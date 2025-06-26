import logging
import time
import win32api
import winerror
import win32pipe
import win32file
import win32security
import ntsecuritycon as con
from .Misc import Client_Garbage_Collected
from pywintypes import error as Win32Error
from win32file import CreateFile, GENERIC_READ, GENERIC_WRITE, OPEN_EXISTING
from typing import Optional


class Pipe:
    '''
    Base class for Pipe_Server and Pipe_Client.
    Implements shared functionality using paired unidirectional pipes.

    Parameters:
    - pipe_name: base name of the pipe (without OS prefix).
    - buffer_size: buffer size in bytes (default: 64 KB).
    '''
    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None):
        self.pipe_name = pipe_name
        self.pipe_in_path = f"\\\\.\\pipe\\{pipe_name}_in"
        self.pipe_out_path = f"\\\\.\\pipe\\{pipe_name}_out"
        self.buffer_size = buffer_size or 64 * 1024
        self.nowait_set = False
        self.pipe_in = None
        self.pipe_out = None

    def Read(self) -> Optional[str]:
        '''
        Reads a message from the input pipe. Blocks unless non-blocking mode is set.

        Returns:
        - Message (str) or None if no data is available (non-blocking mode).

        Raises:
        - Client_Garbage_Collected: if message is 'garbage_collected'.
        - win32api.error: on read failure.
        '''
        try:
            _, data = win32file.ReadFile(self.pipe_in, self.buffer_size)
            message = data.decode()
            if message == 'garbage_collected':
                raise Client_Garbage_Collected()
            return message
        except win32api.error as ex:
            if ex.winerror == winerror.ERROR_NO_DATA and self.nowait_set:
                return None
            logging.error(f"Read error: {ex}")
            raise

    def Write(self, message: str) -> None:
        '''
        Writes a message to the output pipe.

        Raises:
        - win32api.error: on write failure.
        '''
        try:
            win32file.WriteFile(self.pipe_out, message.encode())
        except win32api.error as ex:
            logging.error(f"Write error: {ex}")
            raise

    def Set_Nonblocking(self) -> None:
        '''Sets both pipes to non-blocking mode.'''
        if not self.nowait_set:
            self.nowait_set = True
            for pipe in (self.pipe_in, self.pipe_out):
                win32pipe.SetNamedPipeHandleState(
                    pipe,
                    win32pipe.PIPE_READMODE_MESSAGE | win32pipe.PIPE_NOWAIT,
                    None,
                    None
                )

    def Set_Blocking(self) -> None:
        '''Sets both pipes to blocking mode.'''
        if self.nowait_set:
            self.nowait_set = False
            for pipe in (self.pipe_in, self.pipe_out):
                win32pipe.SetNamedPipeHandleState(
                    pipe,
                    win32pipe.PIPE_READMODE_MESSAGE | win32pipe.PIPE_WAIT,
                    None,
                    None
                )

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.Close()

    def Close(self):
        raise NotImplementedError("Subclasses must implement Close")


class Pipe_Server(Pipe):
    '''
    Named pipe server using two unidirectional pipes.

    Parameters:
    - pipe_name: base name for the pipes.
    - buffer_size: buffer size for the pipes.
    - verbose: enable verbose logging.
    '''
    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None, verbose: bool = False):
        super().__init__(pipe_name, buffer_size)
        self.verbose = verbose
        sec_attr = self._setup_security_attributes()

        try:
            self.pipe_in = win32pipe.CreateNamedPipe(
                self.pipe_in_path,
                win32pipe.PIPE_ACCESS_INBOUND,
                win32pipe.PIPE_TYPE_MESSAGE | win32pipe.PIPE_READMODE_MESSAGE | win32pipe.PIPE_WAIT,
                1,
                self.buffer_size,
                self.buffer_size,
                300,
                sec_attr,
            )
            self.pipe_out = win32pipe.CreateNamedPipe(
                self.pipe_out_path,
                win32pipe.PIPE_ACCESS_OUTBOUND,
                win32pipe.PIPE_TYPE_MESSAGE | win32pipe.PIPE_WAIT,
                1,
                self.buffer_size,
                self.buffer_size,
                300,
                sec_attr,
            )
        except win32api.error as ex:
            logging.exception("Failed to create named pipes")
            raise

        logging.info(f"Started serving: {self.pipe_in_path}, {self.pipe_out_path}")

    def _setup_security_attributes(self) -> Optional[win32security.SECURITY_ATTRIBUTES]:
        '''
        Returns security attributes allowing read/write access to the current user.
        '''
        sec_attr = win32security.SECURITY_ATTRIBUTES()
        sec_desc = sec_attr.SECURITY_DESCRIPTOR
        dacl = win32security.ACL()
        perms_set = False

        account_name = win32api.GetUserName()
        try:
            account_id, _, _ = win32security.LookupAccountName(None, account_name)
            dacl.AddAccessAllowedAce(win32security.ACL_REVISION, con.FILE_GENERIC_READ | con.FILE_GENERIC_WRITE, account_id)
            perms_set = True
            if self.verbose:
                logging.info(f"Pipe ACL set for user: {account_name}")
        except win32api.error as ex:
            if self.verbose:
                logging.warning(f"Failed to set pipe permissions: {ex}")

        if perms_set:
            sec_desc.SetSecurityDescriptorDacl(1, dacl, 0)
            return sec_attr
        return None

    def Connect(self) -> None:
        '''Waits for a client to connect to both named pipes.'''
        for pipe in (self.pipe_in, self.pipe_out):
            try:
                win32pipe.ConnectNamedPipe(pipe, None)
            except win32api.error as e:
                if e.winerror != winerror.ERROR_PIPE_CONNECTED:
                    raise
        logging.info("Client connected")

    def Close(self) -> None:
        '''Flushes and closes both server pipe handles.'''
        logging.info(f"Closing server pipes: {self.pipe_in_path}, {self.pipe_out_path}")
        for pipe in (self.pipe_in, self.pipe_out):
            try:
                win32file.FlushFileBuffers(pipe)
                win32pipe.DisconnectNamedPipe(pipe)
                win32file.CloseHandle(pipe)
            except Exception as e:
                logging.warning(f"Error closing pipe: {e}")

    @staticmethod
    def wait_for_pipe(pipe_name: str, access: int, timeout: float = 5.0, interval: float = 0.1):
        '''Polls until the named pipe is available or timeout occurs.'''
        start = time.time()
        while time.time() - start < timeout:
            try:
                return CreateFile(pipe_name, access, 0, None, OPEN_EXISTING, 0, None)
            except Win32Error as e:
                if e.winerror != winerror.ERROR_FILE_NOT_FOUND:
                    raise
                time.sleep(interval)
        raise TimeoutError(f"Could not connect to pipe: {pipe_name}")


class Pipe_Client(Pipe):
    '''
    Named pipe client using two unidirectional pipes.

    Parameters:
    - pipe_name: base name for the pipes.
    - buffer_size: buffer size for the pipes.
    '''
    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None):
        super().__init__(pipe_name, buffer_size)

        try:
            self.pipe_in = win32file.CreateFile(
                self.pipe_out_path,
                GENERIC_READ,
                0,
                None,
                OPEN_EXISTING,
                0,
                None
            )
            win32pipe.SetNamedPipeHandleState(self.pipe_in, win32pipe.PIPE_READMODE_MESSAGE, None, None)

            self.pipe_out = win32file.CreateFile(
                self.pipe_in_path,
                GENERIC_WRITE,
                0,
                None,
                OPEN_EXISTING,
                0,
                None
            )
        except win32api.error as ex:
            logging.exception("Failed to connect to server pipes")
            raise

        logging.info(f"Client connected to: {self.pipe_in_path}, {self.pipe_out_path}")

    def Close(self) -> None:
        '''Closes both client pipe handles.'''
        logging.info("Closing client pipes")
        for pipe in (self.pipe_in, self.pipe_out):
            try:
                win32file.CloseHandle(pipe)
            except Exception as e:
                logging.warning(f"Error closing client pipe: {e}")
