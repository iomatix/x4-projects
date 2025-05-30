import logging
from typing import Optional, Tuple
import win32api
import winerror
import win32pipe
import win32file
import win32security
import ntsecuritycon as con
from .Misc import Client_Garbage_Collected

# Pipe.py - Communication Layer
# Provides pipe-based communication with Pipe_Server and Pipe_Client.

class Pipe:
    '''
    Base class for Pipe_Server and Pipe_Client.
    Implements shared functionality using paired unidirectional pipes.

    Parameters:
    * pipe_name: String, base name of the pipe without OS path prefix.
    * buffer_size: Int, bytes to reserve for buffers. Defaults to 64 kB.
    '''
    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None):
        self.pipe_name = pipe_name
        self.pipe_in_path = f"\\\\.\\pipe\\{pipe_name}_in"
        self.pipe_out_path = f"\\\\.\\pipe\\{pipe_name}_out"
        self.buffer_size = buffer_size if buffer_size else 64 * 1024
        self.nowait_set = False
        self.pipe_in = None  # For reading
        self.pipe_out = None  # For writing

    def Read(self) -> Optional[str]:
        '''
        Read a message from the input pipe.
        Blocks unless Set_Nonblocking is called.

        Returns:
        * str: Message read from the pipe.
        * None: If no data in non-blocking mode.

        Raises:
        * Client_Garbage_Collected: If "garbage_collected" is received.
        * win32api.error: For other pipe-related errors.
        '''
        try:
            error, data = win32file.ReadFile(self.pipe_in, self.buffer_size)
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
        Write a message to the output pipe.

        Args:
        * message: String to write.

        Raises:
        * win32api.error: If write fails.
        '''
        try:
            win32file.WriteFile(self.pipe_out, message.encode())
        except win32api.error as ex:
            logging.error(f"Write error: {ex}")
            raise

    def Set_Nonblocking(self) -> None:
        '''
        Set both pipes to non-blocking mode.
        '''
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
        '''
        Set both pipes to blocking mode.
        '''
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
    * pipe_name: String, base name for the pipes.
    * buffer_size: Int, buffer size for the pipes.
    * verbose: Bool, if True, log additional information.
    '''
    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None, verbose: bool = False):
        super().__init__(pipe_name, buffer_size)
        self.verbose = verbose
        sec_attr = self._setup_security_attributes()
        
        # Input pipe (server reads, client writes)
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
        
        # Output pipe (server writes, client reads)
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
        logging.info(f"Started serving: {self.pipe_in_path}, {self.pipe_out_path}")

    def _setup_security_attributes(self) -> Optional[win32security.SECURITY_ATTRIBUTES]:
        sec_attr = win32security.SECURITY_ATTRIBUTES()
        sec_desc = sec_attr.SECURITY_DESCRIPTOR
        dacl = win32security.ACL()
        perms_set = False
        for account_name in [win32api.GetUserName()]:
            if not account_name.strip():
                logging.warning("Failed to retrieve account name")
                continue
            try:
                account_id, domain, type = win32security.LookupAccountName(None, account_name)
                dacl.AddAccessAllowedAce(
                    win32security.ACL_REVISION,
                    con.FILE_GENERIC_READ | con.FILE_GENERIC_WRITE,
                    account_id
                )
                perms_set = True
                if self.verbose:
                    logging.info(f"Set permissions for {account_name}")
            except win32api.error as ex:
                if self.verbose:
                    logging.warning(f"Permission set failed for {account_name}: {ex}")
        if perms_set:
            sec_desc.SetSecurityDescriptorDacl(1, dacl, 0)
            return sec_attr
        return None

    def Connect(self) -> None:
        '''
        Wait for a client to connect to both pipes.
        '''
        win32pipe.ConnectNamedPipe(self.pipe_in, None)
        win32pipe.ConnectNamedPipe(self.pipe_out, None)
        logging.info("Connected to client")

    def Close(self) -> None:
        '''
        Close both pipes cleanly.
        '''
        logging.info(f"Closing {self.pipe_in_path}, {self.pipe_out_path}")
        for pipe in (self.pipe_in, self.pipe_out):
            win32file.FlushFileBuffers(pipe)
            win32pipe.DisconnectNamedPipe(pipe)
            win32file.CloseHandle(pipe)

class Pipe_Client(Pipe):
    '''
    Named pipe client using two unidirectional pipes.

    Parameters:
    * pipe_name: String, base name for the pipes.
    * buffer_size: Int, buffer size for the pipes.
    '''
    def __init__(self, pipe_name: str, buffer_size: Optional[int] = None):
        super().__init__(pipe_name, buffer_size)
        
        # Input pipe (client reads, server writes)
        self.pipe_in = win32file.CreateFile(
            self.pipe_out_path,  # Matches server's output
            win32file.GENERIC_READ,
            0,
            None,
            win32file.OPEN_EXISTING,
            0,
            None
        )
        win32pipe.SetNamedPipeHandleState(
            self.pipe_in,
            win32pipe.PIPE_READMODE_MESSAGE,
            None,
            None
        )
        
        # Output pipe (client writes, server reads)
        self.pipe_out = win32file.CreateFile(
            self.pipe_in_path,  # Matches server's input
            win32file.GENERIC_WRITE,
            0,
            None,
            win32file.OPEN_EXISTING,
            0,
            None
        )
        logging.info(f"Client opened: {self.pipe_in_path}, {self.pipe_out_path}")

    def Close(self) -> None:
        '''
        Close both client pipes.
        '''
        logging.info(f"Closing client pipes")
        for pipe in (self.pipe_in, self.pipe_out):
            win32file.CloseHandle(pipe)