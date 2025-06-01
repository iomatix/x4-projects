/*
Lua wrapping for select Win32 API functions:
    open_pipe
    file.write
    file.read
    file.close
    GetLastError

This is based on the lua winapi module from:
https://github.com/stevedonovan/winapi
Original MIT license is located at the bottom of this file.

Changes include removal of most API functions, focusing on pipe-related
operations, adding mode support ("r" and "w") for unidirectional pipes,
and exposing error codes. New comments start with "//--".
*/

#define WINDOWS_LEAN_AND_MEAN
#include <windows.h>
#ifdef __GNUC__
#include <winable.h> /* GNU GCC specific */
#endif

#include <winerror.h>

#define FILE_BUFF_SIZE 2048

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

// Guard against EXPORT redefinition
#ifndef EXPORT
#ifdef WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif
#endif

#if LUA_VERSION_NUM > 501
#define lua_objlen lua_rawlen
#else
#define lua_objlen(L, idx) (luaL_checklstring(L, idx, NULL), lua_strlen(L, idx))
#endif

//-- Utility functions from wutils.h (simplified).
typedef int Ref;

int push_error_msg(lua_State* L, const char* msg) {
    lua_pushnil(L);
    lua_pushstring(L, msg);
    return 2;
}

const char* last_error(int err) {
    static char errbuff[512];
    int sz;
    if (err == 0) err = GetLastError();
    sz = FormatMessageA(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL, err,
        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        errbuff, sizeof(errbuff), NULL
    );
    if (sz < 2) sz = 2;
    errbuff[sz - 2] = '\0'; // Strip \r\n
    return errbuff;
}

int push_error(lua_State* L) {
    return push_error_msg(L, last_error(0));
}

void release_ref(lua_State* L, Ref ref) {
    luaL_unref(L, LUA_REGISTRYINDEX, ref);
}

//-- Callback data structure for background operations (unused for now).
typedef struct {
    HANDLE handle;
    lua_State* L;
    Ref callback;
    char* buf;
    int bufsz;
} LuaCallback, * PLuaCallback;

void lcb_allocate_buffer(void* data, int size) {
    LuaCallback* lcb = (LuaCallback*)data;
    lcb->buf = malloc(size);
    lcb->bufsz = size;
}

void lcb_free(void* data) {
    LuaCallback* lcb = (LuaCallback*)data;
    if (!lcb) return;
    if (lcb->buf) free(lcb->buf);
    if (lcb->handle) CloseHandle(lcb->handle);
    release_ref(lcb->L, lcb->callback);
}

#define lcb_buf(data) ((LuaCallback *)data)->buf
#define lcb_bufsz(data) ((LuaCallback *)data)->bufsz
#define lcb_handle(data) ((LuaCallback *)data)->handle

//-- File structure to represent a Windows file handle.
typedef struct {
    HANDLE handle;  // Read handle
    HANDLE hWrite;  // Write handle (may differ for unidirectional pipes)
    lua_State* L;
    char* buf;
    int bufsz;
} File;

#define File_MT "File"

File* File_arg(lua_State* L, int idx) {
    File* this = (File*)luaL_checkudata(L, idx, File_MT);
    luaL_argcheck(L, this != NULL, idx, "File expected");
    return this;
}

static void File_ctor(lua_State* L, File* this, HANDLE hread, HANDLE hwrite);

static int push_new_File(lua_State* L, HANDLE hread, HANDLE hwrite) {
    File* this = (File*)lua_newuserdata(L, sizeof(File));
    luaL_getmetatable(L, File_MT);
    lua_setmetatable(L, -2);
    File_ctor(L, this, hread, hwrite);
    return 1;
}

static void File_ctor(lua_State* L, File* this, HANDLE hread, HANDLE hwrite) {
    this->handle = hread;
    this->hWrite = hwrite;
    this->L = L;
    lcb_allocate_buffer(this, FILE_BUFF_SIZE);
}

//-- Write to the file (uses hWrite handle).
static int l_File_write(lua_State* L) {
    File* this = File_arg(L, 1);
    const char* s = luaL_checklstring(L, 2, NULL);
    DWORD bytesWrote;
    WriteFile(this->hWrite, s, (DWORD)lua_objlen(L, 2), &bytesWrote, NULL);
    lua_pushinteger(L, bytesWrote);
    return 1;
}

//-- Read from the file (uses handle for reading).
static BOOL raw_read(File* this) {
    DWORD bytesRead = 0;
    BOOL res = ReadFile(this->handle, this->buf, this->bufsz, &bytesRead, NULL);
    this->buf[bytesRead] = '\0';
    return res && bytesRead;
}

static int l_File_read(lua_State* L) {
    File* this = File_arg(L, 1);
    if (raw_read(this)) {
        lua_pushstring(L, this->buf);
        return 1;
    }
    else {
        return push_error(L);
    }
}

//-- Expose GetLastError for error handling.
static int l_GetLastError(lua_State* L) {
    lua_pushinteger(L, GetLastError());
    return 1;
}

//-- Close both handles if different.
static int l_File_close(lua_State* L) {
    File* this = File_arg(L, 1);
    if (this->hWrite && this->hWrite != this->handle) CloseHandle(this->hWrite);
    if (this->handle) CloseHandle(this->handle);
    lcb_free(this);
    return 0;
}

//-- Garbage collection to free resources.
static int l_File___gc(lua_State* L) {
    File* this = File_arg(L, 1);
    if (this->buf) {
        free(this->buf);
        this->buf = NULL;  // Prevent double-free issues
    }
    if (this->hWrite && this->hWrite != this->handle) CloseHandle(this->hWrite);
    if (this->handle) CloseHandle(this->handle);
    return 0;
}

static const struct luaL_Reg File_methods[] = {
    {"write", l_File_write},
    {"read", l_File_read},
    {"close", l_File_close},
    {"__gc", l_File___gc},
    {NULL, NULL}
};

static void File_register(lua_State* L) {
    luaL_newmetatable(L, File_MT);
#if LUA_VERSION_NUM > 501
    luaL_openlib(L, NULL, File_methods, 0);
#else
    luaL_register(L, NULL, File_methods);
#endif
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
}

/// Open a named pipe with specified mode ("r" for read, "w" for write).
// @param pipename The pipe name (e.g., "\\.\pipe\x4_python_host_in")
// @param mode The access mode ("r" or "w")
// @return File object on success, nil plus error on failure
static int l_open_pipe(lua_State* L) {
    const char* pipename = luaL_checklstring(L, 1, NULL);
    const char* mode = luaL_checklstring(L, 2, NULL);

    DWORD access = 0;
    if (strcmp(mode, "r") == 0) {
        access = GENERIC_READ;
    }
    else if (strcmp(mode, "w") == 0) {
        access = GENERIC_WRITE;
    }
    else {
        return push_error_msg(L, "Invalid mode: must be 'r' or 'w'");
    }

    HANDLE hPipe = CreateFileA(
        pipename,
        access,
        0,              // No sharing
        NULL,           // Default security attributes
        OPEN_EXISTING,  // Opens existing pipe
        FILE_FLAG_OVERLAPPED,  // Non-blocking mode
        NULL            // No template file
    );

    if (hPipe == INVALID_HANDLE_VALUE) {
        return push_error(L);
    }

    // Configure pipe for message mode and non-blocking behavior
    DWORD modeFlags = PIPE_READMODE_MESSAGE | PIPE_NOWAIT;
    if (!SetNamedPipeHandleState(hPipe, &modeFlags, NULL, NULL)) {
        CloseHandle(hPipe);
        return push_error(L);
    }

    // Return a File object with appropriate read/write handles
    return push_new_File(L, (access == GENERIC_READ) ? hPipe : NULL,
        (access == GENERIC_WRITE) ? hPipe : NULL);
}

static const luaL_Reg winpipe_funs[] = {
    {"GetLastError", l_GetLastError},
    {"open_pipe", l_open_pipe},
    {NULL, NULL}
};

EXPORT int luaopen_winpipe(lua_State* L) {
#if LUA_VERSION_NUM > 501
    luaL_openlib(L, "winpipe", winpipe_funs, 0);
    lua_pushvalue(L, -1);
    lua_setglobal(L, "winpipe");
#else
    luaL_register(L, "winpipe", winpipe_funs);
#endif

    File_register(L);

    // Expose error code constants
    lua_pushinteger(L, ERROR_IO_PENDING);
    lua_setfield(L, -2, "ERROR_IO_PENDING");
    lua_pushinteger(L, ERROR_NO_DATA);
    lua_setfield(L, -2, "ERROR_NO_DATA");

    return 1;
}

/*
MIT License for original winapi module:
Copyright (c) 2007-2013 Steve Donovan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/