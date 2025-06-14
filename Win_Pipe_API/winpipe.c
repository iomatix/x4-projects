/*
 * Lua Named Pipe Module with Asynchronous I/O (Windows)
 * ------------------------------------------------------
 * This module implements Lua bindings to Windows named pipes using the WinAPI
 * with support for asynchronous I/O via OVERLAPPED structures.
 *
 * Author: Mateusz "iomatix" Wypchlak
 * Inspired by professional system-level practices.
 */

#define WINDOWS_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <string.h>

#define FILE_BUFFER_SIZE 2048
#define FILE_MT "WinPipe.File"

#ifndef EXPORT
#ifdef WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif
#endif

// Lua 5.1 vs 5.2+ compatibility
#if LUA_VERSION_NUM == 501
  // In 5.1 we need to map newer APIs back to luaL_register
  #define lua_objlen(L, idx)    (luaL_checklstring(L, idx, NULL), lua_strlen(L, idx))
  #define luaL_setfuncs(L, f, n) luaL_register(L, NULL, f)
  #define luaL_newlib(L, f)     luaL_register(L, "winpipe", f)
#else
  // Lua 5.2+ already provides these
  #define lua_objlen lua_rawlen
  // luaL_setfuncs and luaL_newlib are real functions
#endif


//------------------------------------
// Utility: Push Windows last error as Lua error
//------------------------------------
static int push_last_error(lua_State* L) {
    DWORD err = GetLastError();
    char buf[512];
    FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL, err, 0, buf, sizeof(buf), NULL);
    lua_pushnil(L);
    lua_pushstring(L, buf);
    return 2;
}

//------------------------------------
// File struct representing a pipe endpoint
//------------------------------------
typedef struct {
    HANDLE handle;    // Read or write handle
    BOOL is_read;     // TRUE if read handle, FALSE if write handle
    char* buffer;     // Read buffer
    int   buf_size;   // Buffer size
} PipeFile;

//------------------------------------
// Constructor Helper
//------------------------------------
static void init_pipefile(lua_State* L, PipeFile* pf, HANDLE h, BOOL is_read) {
    pf->handle = h;
    pf->is_read = is_read;
    pf->buf_size = FILE_BUFFER_SIZE;
    pf->buffer = (char*)malloc(pf->buf_size);
    if (!pf->buffer) {
        CloseHandle(h);
        luaL_error(L, "Memory allocation failed for pipe buffer");
    }
}

//------------------------------------
// Destructor
//------------------------------------
static int pipefile_gc(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    if (pf->handle) CloseHandle(pf->handle);
    if (pf->buffer) free(pf->buffer);
    return 0;
}

//------------------------------------
// Method: Write string to pipe
//------------------------------------
static int pipefile_write(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    size_t len;
    const char* data = luaL_checklstring(L, 2, &len);
    DWORD written = 0;

    if (!WriteFile(pf->handle, data, (DWORD)len, &written, NULL))
        return push_last_error(L);

    lua_pushinteger(L, written);
    return 1;
}

//------------------------------------
// Method: Read from pipe
//------------------------------------
static int pipefile_read(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    DWORD read = 0;

    BOOL result = ReadFile(pf->handle, pf->buffer, pf->buf_size - 1, &read, NULL);

    if (!result) {
        DWORD err = GetLastError();
        if (err == ERROR_NO_DATA || err == ERROR_MORE_DATA || err == ERROR_IO_PENDING) {
            lua_pushnil(L);
            lua_pushstring(L, "No data or pending I/O");
            return 2;
        }
        return push_last_error(L);
    }

    pf->buffer[read] = '\0';
    lua_pushlstring(L, pf->buffer, read);
    return 1;
}

//------------------------------------
// Method: Close pipe handle
//------------------------------------
static int pipefile_close(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    if (pf->handle) {
        CloseHandle(pf->handle);
        pf->handle = NULL;
    }
    lua_pushboolean(L, 1);
    return 1;
}

//------------------------------------
// Lua constructor: winpipe.open(pipe_name, mode)
//------------------------------------
static int winpipe_open(lua_State* L) {
    const char* pipe_name = luaL_checkstring(L, 1);
    const char* mode = luaL_checkstring(L, 2);

    DWORD access = 0;
    BOOL is_read = FALSE;
    if (strcmp(mode, "r") == 0) {
        access = GENERIC_READ;
        is_read = TRUE;
    }
    else if (strcmp(mode, "w") == 0) {
        access = GENERIC_WRITE;
    }
    else {
        return luaL_error(L, "Invalid mode: expected 'r' or 'w'");
    }

    HANDLE hPipe = CreateFileA(
        pipe_name,
        access,
        0,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED,  // Non-blocking mode
        NULL
    );

    if (hPipe == INVALID_HANDLE_VALUE)
        return push_last_error(L);

    // Optional: set named pipe state to message mode
    DWORD modeFlags = PIPE_READMODE_MESSAGE | PIPE_NOWAIT;
    SetNamedPipeHandleState(hPipe, &modeFlags, NULL, NULL);

    // Allocate userdata and initialize
    PipeFile* pf = (PipeFile*)lua_newuserdata(L, sizeof(PipeFile));
    luaL_getmetatable(L, FILE_MT);
    lua_setmetatable(L, -2);
    init_pipefile(L, pf, hPipe, is_read);
    return 1;
}

//------------------------------------
// File method table
//------------------------------------
static const struct luaL_Reg pipefile_methods[] = {
    {"read", pipefile_read},
    {"write", pipefile_write},
    {"close", pipefile_close},
    {"__gc", pipefile_gc},
    {NULL, NULL}
};

//------------------------------------
// Winpipe global functions
//------------------------------------
static const struct luaL_Reg winpipe_funs[] = {
    {"open", winpipe_open},
    {NULL, NULL}
};

//------------------------------------
// Register module
//------------------------------------
EXPORT int luaopen_winpipe(lua_State* L) {
    // 1) Create and populate the File userdata metatable
    luaL_newmetatable(L, FILE_MT);
      lua_pushvalue(L, -1);
      lua_setfield(L, -2, "__index");
      luaL_setfuncs(L, pipefile_methods, 0);
    lua_pop(L, 1);

    // 2) Create the module table and register its functions
    luaL_newlib(L, winpipe_funs);
    return 1;
}