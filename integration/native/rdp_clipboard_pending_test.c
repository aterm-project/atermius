// Tests queuing clipboard text before CLIPRDR negotiation. No connection is made.
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <stdint.h>

typedef void* (*Create)(const char*, int, const char*, const char*, const char*, const char*);
typedef int (*Paste)(void*, const BYTE*, uint32_t);
typedef void (*Free)(void*);
int wmain(int argc, wchar_t** argv) {
  assert(argc == 2);
  HMODULE dll = LoadLibraryW(argv[1]);
  assert(dll);
  Create create = (Create)GetProcAddress(dll, "aterm_rdp_create_ex");
  Paste paste = (Paste)GetProcAddress(dll, "aterm_rdp_paste");
  Free release = (Free)GetProcAddress(dll, "aterm_rdp_free");
  assert(create && paste && release);
  const BYTE text[] = {0x2d,0x4e,0x87,0x65,0x3d,0xd8,0x00,0xde};
  void* ctx = create("127.0.0.1", 1, "fixture", "fixture", "", "version=1\naudio=0\nclipboard=1\n");
  assert(ctx);
  assert(paste(ctx, text, sizeof(text)) == 1);
  assert(paste(ctx, (const BYTE*)L"replacement", 22) == 1);
  assert(paste(ctx, NULL, 0) == 1);
  assert(paste(ctx, NULL, 2) == 0);
  assert(paste(ctx, text, 3) == 0);
  assert(paste(ctx, text, 131074) == 0);
  assert(paste(NULL, text, sizeof(text)) == 0);
  release(ctx);
  ctx = create("127.0.0.1", 1, "fixture", "fixture", "", "version=1\naudio=0\nclipboard=0\n");
  assert(ctx);
  assert(paste(ctx, text, sizeof(text)) == 0);
  release(ctx);
  FreeLibrary(dll);
  puts("RDP clipboard pending negotiation passed");
}
