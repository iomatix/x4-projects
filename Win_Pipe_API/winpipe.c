/*
 * winpipe.c — Lua Named-Pipe Module with True Non-Blocking I/O (Windows)
 * ----------------------------------------------------------------------
 * Exposes overlapped, unidirectional pipe read/write + peek functionality
 * to Lua via:
 *
 *   winpipe.open_pipe(name, mode)   → WinPipe.File userdata
 *   file:read_pipe()                → (data) or (nil, err)
 *   file:write_pipe(data)           → (bytes_written) or (nil, err)
 *   file:close_pipe()               → (true)
 *   winpipe.peek_pipe(file)         → (bytes_available) or (nil, err)
 *
 * Author: Mateusz “iomatix” Wypchlak
 * Refactored for non-blocking I/O, inspired by Microsoft best practices.
 */

#define WINDOWS_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>

#define FILE_BUFFER_SIZE  2048
#define FILE_MT           "WinPipe.File"

#ifndef LUA_OK
#define LUA_OK 0
#endif

#ifndef LUA_ERRRUN
#define LUA_ERRRUN 2
#endif

#ifndef LUA_ERRMEM
#define LUA_ERRMEM 4
#endif

 //------------------------------------------------------------------------------
 // Cross-Lua versions compatibility
 //------------------------------------------------------------------------------
#if LUA_VERSION_NUM == 501
#define luaL_setfuncs(L,f,n)  luaL_register(L,NULL,f)
#define luaL_newlib(L,f)      luaL_register(L,"winpipe",f)
#endif

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

//------------------------------------------------------------------------------
// Helper: Push a Windows error into Lua as (nil, errmsg)
//------------------------------------------------------------------------------
static int push_last_error(lua_State* L) {
    DWORD err = GetLastError();
    LPSTR buf = NULL;
    FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER |
        FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL, err, 0,
        (LPSTR)&buf, 0, NULL
    );
    lua_pushnil(L);
    lua_pushfstring(L, "WinAPI Error %lu: %s", err, buf ? buf : "Unknown");
    if (buf) LocalFree(buf);
    return 2;
}

//------------------------------------------------------------------------------
// Helper: Push a custom Windows error message into Lua (nil, msg)
//------------------------------------------------------------------------------
static int push_win_error(lua_State* L, const char* msg, DWORD err) {
    LPSTR buf = NULL;
    FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER |
        FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL, err, 0,
        (LPSTR)&buf, 0, NULL
    );
    lua_pushnil(L);
    lua_pushfstring(L, "%s (WinAPI Error %lu: %s)", msg, err, buf ? buf : "Unknown");
    if (buf) LocalFree(buf);
    return 2;
}

//------------------------------------------------------------------------------
// PipeFile userdata: holds a HANDLE + OVERLAPPED + buffer
//------------------------------------------------------------------------------
typedef struct {
    HANDLE      handle;
    BOOL        is_read;
    char* buffer;
    DWORD       buf_size;
    OVERLAPPED  ov;
} PipeFile;

//------------------------------------------------------------------------------
// Initialize a PipeFile: alloc buffer + create event for overlapped
//------------------------------------------------------------------------------
static int init_pipefile(lua_State* L, PipeFile* pf, HANDLE h, BOOL is_read) {
    pf->handle = h;
    pf->is_read = is_read;
    pf->buf_size = FILE_BUFFER_SIZE;

    pf->buffer = (char*)malloc(pf->buf_size);
    if (!pf->buffer) {
        CloseHandle(h);
        lua_pushstring(L, "Memory allocation failed for pipe buffer");
        return LUA_ERRMEM;
    }

    ZeroMemory(&pf->ov, sizeof(OVERLAPPED));
    pf->ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!pf->ov.hEvent) {
        free(pf->buffer);
        CloseHandle(h);
        lua_pushstring(L, "Failed to create OVERLAPPED event");
        return LUA_ERRRUN;
    }

    return LUA_OK;
}


//------------------------------------------------------------------------------
// GC metamethod: close handles + free buffer
//------------------------------------------------------------------------------
static int pipefile_gc(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    if (pf->handle && pf->handle != INVALID_HANDLE_VALUE)
        CloseHandle(pf->handle);
    if (pf->ov.hEvent) CloseHandle(pf->ov.hEvent);
    if (pf->buffer)   free(pf->buffer);
    return 0;
}

//------------------------------------------------------------------------------
// Method: file:write_pipe(data)
// Asynchronous WriteFile + GetOverlappedResult
//------------------------------------------------------------------------------
static int pipefile_write(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    size_t    len;
    const char* data = luaL_checklstring(L, 2, &len);
    DWORD     written = 0;

    // reset event & offsets
    ResetEvent(pf->ov.hEvent);
    pf->ov.Offset = pf->ov.OffsetHigh = 0;

    BOOL ok = WriteFile(pf->handle, data, (DWORD)len, NULL, &pf->ov);
    if (!ok) {
        DWORD err = GetLastError();
        if (err == ERROR_IO_PENDING) {
            if (!GetOverlappedResult(pf->handle, &pf->ov, &written, TRUE))
                return push_last_error(L);
        }
        else {
            return push_last_error(L);
        }
    }
    else {
        written = pf->ov.InternalHigh;
    }

    lua_pushinteger(L, written);
    return 1;
}

//------------------------------------------------------------------------------
// Method: file:read_pipe()
// Asynchronous ReadFile + GetOverlappedResult
//------------------------------------------------------------------------------
static int pipefile_read(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    DWORD     read = 0;

    ResetEvent(pf->ov.hEvent);
    pf->ov.Offset = pf->ov.OffsetHigh = 0;

    BOOL ok = ReadFile(pf->handle, pf->buffer, pf->buf_size - 1, NULL, &pf->ov);
    if (!ok) {
        DWORD err = GetLastError();
        if (err == ERROR_IO_PENDING) {
            if (!GetOverlappedResult(pf->handle, &pf->ov, &read, TRUE))
                return push_last_error(L);
        }
        else {
            return push_last_error(L);
        }
    }
    else {
        read = pf->ov.InternalHigh;
    }

    pf->buffer[read] = '\0';
    lua_pushlstring(L, pf->buffer, read);
    return 1;
}

//------------------------------------------------------------------------------
// Method: file:close_pipe()
//------------------------------------------------------------------------------
static int pipefile_close(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    if (pf->handle && pf->handle != INVALID_HANDLE_VALUE)
        CloseHandle(pf->handle);
    pf->handle = INVALID_HANDLE_VALUE;
    lua_pushboolean(L, 1);
    return 1;
}

//------------------------------------------------------------------------------
// Method: file:peek_pipe()
// Wraps PeekNamedPipe to report bytes available without reading
//------------------------------------------------------------------------------
static int pipefile_peek(lua_State* L) {
    PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
    DWORD avail = 0;
    BOOL ok = PeekNamedPipe(pf->handle,
        NULL, 0,      // no data copy
        NULL,
        &avail,      // bytes available
        NULL);
    if (!ok) return push_last_error(L);
    lua_pushinteger(L, avail);
    return 1;
}

//------------------------------------------------------------------------------
// Global: winpipe.open_pipe(name, mode)
//------------------------------------------------------------------------------
static int l_open_pipe(lua_State* L) {
	const char* pname = luaL_checkstring(L, 1);
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
		return luaL_error(L, "mode must be 'r' or 'w'");
	}

	HANDLE h = CreateFileA(
		pname, access, 0, NULL,
		OPEN_EXISTING,
		FILE_FLAG_OVERLAPPED,
		NULL
	);
	if (h == INVALID_HANDLE_VALUE)
		return push_last_error(L);

	// Best-effort: set non-blocking message mode
	DWORD flags = PIPE_READMODE_MESSAGE | PIPE_NOWAIT;
	if (!SetNamedPipeHandleState(h, &flags, NULL, NULL)) {
		DWORD err = GetLastError();

        // Don't bail immediately on error, allow to block on read/write sometimes
        // CloseHandle(h);
		// return push_win_error(L, "SetNamedPipeHandleState failed", err);
	}

	// Allocate userdata and assign metatable
	PipeFile* pf = (PipeFile*)lua_newuserdata(L, sizeof(PipeFile));
	luaL_getmetatable(L, FILE_MT);
	lua_setmetatable(L, -2);

    if (init_pipefile(L, pf, h, is_read) != LUA_OK)
        return lua_error(L);
	return 1;
}


//------------------------------------------------------------------------------
// Register everything with Lua
//------------------------------------------------------------------------------
static const luaL_Reg pipefile_methods[] = {
    {"read_pipe",  pipefile_read},
    {"write_pipe", pipefile_write},
    {"close_pipe", pipefile_close},
    {"peek_pipe",  pipefile_peek},
    {"__gc",       pipefile_gc},
    {NULL,NULL}
};

static const struct luaL_Reg winpipe_functions[] = {
    {"open_pipe", l_open_pipe},
    {NULL, NULL}
};

#ifdef __cplusplus
extern "C" {
#endif

    EXPORT int luaopen_winpipe(lua_State* L) {
        // create metatable for PipeFile
        luaL_newmetatable(L, FILE_MT);
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        luaL_setfuncs(L, pipefile_methods, 0);
        lua_pop(L, 1);

        // export module functions
        luaL_newlib(L, winpipe_functions);
        return 1;
    }

#ifdef __cplusplus
}
#endif
