import time
from pathlib import Path
from typing import Optional

# Log_Reader.py - Logging Utility
# Reads log files incrementally and trims them if they exceed a size limit.

class Log_Reader:
    '''
    Class for reading game output log files incrementally.
    Advances to the end of the log on initialization and reads new lines as they appear.

    Parameters:
    * log_path: Path to the log file (str or Path object).

    Attributes:
    * file: Open file instance, typically positioned at the end.
    * partial_line: Partially read line for the current read attempt.
    '''
    def __init__(self, log_path: str | Path):
        # Convert to Path object if string is provided
        log_path = Path(log_path) if isinstance(log_path, str) else log_path
        self.file = log_path.open('r')
        self.partial_line = ''
        # Seek to the end of the file
        self.file.seek(0, 2)

    def readline(self, timeout: Optional[float] = None) -> Optional[str]:
        '''
        Read a line from the log file with an optional timeout.

        Args:
        * timeout: Maximum seconds to wait for a line. If None, blocks indefinitely.

        Returns:
        * str: The next log line, or None if timeout is reached.
        '''
        start_time = time.time()
        while True:
            chunk = self.file.readline()
            if chunk:
                self.partial_line += chunk
                if self.partial_line.endswith('\n'):
                    line = self.partial_line[:-1]
                    self.partial_line = ''
                    return line
            else:
                if timeout is not None and (time.time() - start_time) > timeout:
                    return None
                time.sleep(0.1)

    def trim_log(self, max_size: int = 1024 * 1024) -> None:
        '''
        Trim the log file to keep only the last part if it exceeds max_size.

        Args:
        * max_size: Maximum file size in bytes before trimming (default: 1MB).
        '''
        current_pos = self.file.tell()
        if current_pos > max_size:
            # Read all data from the current position
            self.file.seek(0)
            data = self.file.read()
            # Keep the last max_size bytes
            trimmed_data = data[-max_size:]
            # Truncate and rewrite
            self.file.seek(0)
            self.file.truncate()
            self.file.write(trimmed_data)
            self.file.flush()
            # Reset to end
            self.file.seek(0, 2)