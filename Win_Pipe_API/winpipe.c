/*
 * Lua Named Pipe Module with Asynchronous I/O (Windows)
 * ------------------------------------------------------
 * This module implements Lua bindings to Windows named pipes using the WinAPI
 * with full support for asynchronous (non-blocking) I/O via OVERLAPPED structures.
 *
 * Author: Mateusz "iomatix" Wypchlak
 * Inspired by professional system-level practices.
 */

#define WINDOWS_LEAN_AND_MEAN
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>

#define FILE_BUFFER_SIZE 2048
#define FILE_MT "WinPipe.File"

 // Lua compatibility macros for Lua 5.1 and 5.2+
#if LUA_VERSION_NUM == 501
#define lua_objlen(L, idx)    (luaL_checklstring(L, idx, NULL), lua_strlen(L, idx))
#define luaL_setfuncs(L, f, n) luaL_register(L, NULL, f)
#define luaL_newlib(L, f)     luaL_register(L, "winpipe", f)
#else
#define lua_objlen lua_rawlen
#endif

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

//------------------------------------
// Utility: Push Windows last error as Lua error
//------------------------------------
static int push_last_error(lua_State* L) {
	DWORD err = GetLastError();
	LPSTR buf = NULL;
	FormatMessageA(
		FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		NULL, err, 0, (LPSTR)&buf, 0, NULL
	);

	lua_pushnil(L);
	lua_pushfstring(L, "WinAPI Error %lu: %s", err, buf ? buf : "Unknown error");
	if (buf) LocalFree(buf);
	return 2;
}

//------------------------------------
// PipeFile: Represents one side of the pipe
//------------------------------------
typedef struct {
	HANDLE handle;        // Windows handle to the pipe
	BOOL is_read;         // TRUE if opened for reading
	char* buffer;         // Read buffer
	int   buf_size;       // Size of the buffer
	OVERLAPPED ov;        // Overlapped structure for async I/O
} PipeFile;

//------------------------------------
// Constructor Helper: Initialize PipeFile structure
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

	ZeroMemory(&pf->ov, sizeof(OVERLAPPED));
	pf->ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
	if (!pf->ov.hEvent) {
		free(pf->buffer);
		CloseHandle(h);
		luaL_error(L, "Could not create OVERLAPPED event");
	}
}

//------------------------------------
// Destructor: __gc metamethod for PipeFile
//------------------------------------
static int pipefile_gc(lua_State* L) {
	PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
	if (pf->handle && pf->handle != INVALID_HANDLE_VALUE) CloseHandle(pf->handle);
	if (pf->buffer) free(pf->buffer);
	if (pf->ov.hEvent) CloseHandle(pf->ov.hEvent);
	return 0;
}

//------------------------------------
// Method: pipefile:write(data)
//------------------------------------
static int pipefile_write(lua_State* L) {
	PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
	size_t len;
	const char* data = luaL_checklstring(L, 2, &len);
	DWORD transferred = 0;

	// Prepare OVERLAPPED
	pf->ov.Offset = 0;
	pf->ov.OffsetHigh = 0;
	ResetEvent(pf->ov.hEvent);

	BOOL success = WriteFile(pf->handle, data, (DWORD)len, &transferred, &pf->ov);
	if (!success) {
		DWORD err = GetLastError();
		if (err == ERROR_IO_PENDING) {
			if (!GetOverlappedResult(pf->handle, &pf->ov, &transferred, TRUE))
				return push_last_error(L);
		}
		else {
			return push_last_error(L);
		}
	}
	lua_pushinteger(L, transferred);
	return 1;
}

//------------------------------------
// Method: pipefile:read()
//------------------------------------
static int pipefile_read(lua_State* L) {
	PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
	DWORD transferred = 0;

	// Prepare OVERLAPPED
	pf->ov.Offset = 0;
	pf->ov.OffsetHigh = 0;
	ResetEvent(pf->ov.hEvent);

	BOOL success = ReadFile(pf->handle, pf->buffer, pf->buf_size - 1, &transferred, &pf->ov);
	if (!success) {
		DWORD err = GetLastError();
		if (err == ERROR_IO_PENDING) {
			if (!GetOverlappedResult(pf->handle, &pf->ov, &transferred, TRUE))
				return push_last_error(L);
		}
		else {
			return push_last_error(L);
		}
	}
	pf->buffer[transferred] = '\0';
	lua_pushlstring(L, pf->buffer, transferred);
	return 1;
}

//------------------------------------
// Method: pipefile:close()
//------------------------------------
static int pipefile_close(lua_State* L) {
	PipeFile* pf = (PipeFile*)luaL_checkudata(L, 1, FILE_MT);
	if (pf->handle && pf->handle != INVALID_HANDLE_VALUE) {
		CloseHandle(pf->handle);
		pf->handle = INVALID_HANDLE_VALUE;
	}
	lua_pushboolean(L, 1);
	return 1;
}

//------------------------------------
// Constructor: winpipe.open(pipe_name, mode)
// mode: "r" or "w"
//------------------------------------
static int winpipe_open(lua_State* L) {
	const char* pname = luaL_checkstring(L, 1);
	const char* mode = luaL_checkstring(L, 2);

	if (strcmp(mode, "r") != 0 && strcmp(mode, "w") != 0)
		return luaL_error(L, "Invalid mode: '%s'. Use 'r' or 'w'.", mode);

	DWORD access = (strcmp(mode, "r") == 0) ? GENERIC_READ : GENERIC_WRITE;
	BOOL is_read = (strcmp(mode, "r") == 0);

	HANDLE hPipe = CreateFileA(
		pname,
		access,
		0,              // No sharing
		NULL,           // Default security
		OPEN_EXISTING,
		FILE_FLAG_OVERLAPPED,
		NULL
	);
	if (hPipe == INVALID_HANDLE_VALUE) return push_last_error(L);

	// Ensure pipe is in message mode + non-blocking (optional)
	DWORD modeFlags = PIPE_READMODE_MESSAGE | PIPE_NOWAIT;
	SetNamedPipeHandleState(hPipe, &modeFlags, NULL, NULL);  // Best effort, ignore failure

	PipeFile* pf = (PipeFile*)lua_newuserdata(L, sizeof(PipeFile));
	luaL_getmetatable(L, FILE_MT);
	lua_setmetatable(L, -2);

	init_pipefile(L, pf, hPipe, is_read);
	return 1;
}

//------------------------------------
// Metamethod: tostring()
//------------------------------------
static int pipefile_tostring(lua_State* L) {
	PipeFile* pf = luaL_checkudata(L, 1, FILE_MT);
	lua_pushfstring(L, "WinPipe.File: %p (%s)", pf->handle, pf->is_read ? "read" : "write");
	return 1;
}

//------------------------------------
// PipeFile method table
//------------------------------------
static const struct luaL_Reg pipefile_methods[] = {
	{"read",  pipefile_read},
	{"write", pipefile_write},
	{"close", pipefile_close},
	{"__gc",  pipefile_gc},
	{"__tostring", pipefile_tostring},
	{NULL, NULL}
};

//------------------------------------
// Global functions for winpipe module
//------------------------------------
static const luaL_Reg winpipe_funs[] = {
	{ "open_pipe", winpipe_open  },
	{ NULL, NULL }
};
#ifdef __cplusplus
extern "C" {
#endif

	// Entry point for Lua module loader
	EXPORT int luaopen_winpipe(lua_State* L) {
		luaL_newmetatable(L, FILE_MT);
		lua_pushvalue(L, -1);
		lua_setfield(L, -2, "__index");
		luaL_setfuncs(L, pipefile_methods, 0);
		lua_pop(L, 1);

		luaL_newlib(L, winpipe_funs);
		return 1;
	}

#ifdef __cplusplus
}
#endif
