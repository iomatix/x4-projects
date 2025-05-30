# Misc.py - Custom Exceptions
# Defines Client_Garbage_Collected for pipe-specific error handling.

class Client_Garbage_Collected(Exception):
    '''
    Custom exception raised when a client pipe is garbage collected.
    Used as an alternative to proper file closing due to crashes in X4 v3.0.
    '''