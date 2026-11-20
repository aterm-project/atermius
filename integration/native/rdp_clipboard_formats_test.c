// Build with the engine's FreeRDP/OpenSSL flags, like rdp_pointer_probe.c.
#include "../../apps/client/native/desktop/atermius_rdp.c"
#undef NDEBUG
#include <assert.h>

static unsigned requests;
static UINT32 requested_id;

static UINT acknowledge(CliprdrClientContext* clip, const CLIPRDR_FORMAT_LIST_RESPONSE* response) {
  (void)clip;
  assert(response->common.msgFlags == CB_RESPONSE_OK);
  return CHANNEL_RC_OK;
}

static UINT request(CliprdrClientContext* clip, const CLIPRDR_FORMAT_DATA_REQUEST* data) {
  (void)clip;
  requests++;
  requested_id = data->requestedFormatId;
  return CHANNEL_RC_OK;
}

static UINT announce(CliprdrClientContext* clip, const CLIPRDR_FORMAT_LIST* list) {
  (void)clip;
  assert(list->numFormats == 1 && list->formats[0].formatId == CF_UNICODETEXT);
  return CHANNEL_RC_OK;
}

int main(void) {
  AtermContext c = {0};
  CliprdrClientContext clip = {0};
  InitializeCriticalSection(&c.lock);
  c.clipboard_ready = c.clipboard_enabled = c.files_enabled = TRUE;
  c.clip = &clip;
  clip.custom = &c;
  clip.ClientFormatListResponse = acknowledge;
  clip.ClientFormatDataRequest = request;
  clip.ClientFormatList = announce;

  CLIPRDR_FORMAT formats[] = {{CF_UNICODETEXT, NULL}, {0xc001, FILE_GROUP_DESCRIPTOR_W}};
  CLIPRDR_FORMAT_LIST list = {0};
  list.formats = formats;
  list.numFormats = 2;
  assert(clip_formats(&clip, &list) == CHANNEL_RC_OK);
  assert(requests == 1 && requested_id == CF_UNICODETEXT);
  assert(clip_formats(&clip, &list) == CHANNEL_RC_OK);
  assert(requests == 1);

  // A stale response advances the queue without publishing text. The latest
  // text is requested first, and its file descriptors are requested second.
  const BYTE text[] = {0x2d, 0x4e, 0x87, 0x65, 0, 0};
  CLIPRDR_FORMAT_DATA_RESPONSE reply = {0};
  reply.common.msgFlags = CB_RESPONSE_OK;
  reply.common.dataLen = sizeof(text);
  reply.requestedFormatData = text;
  assert(clip_data(&clip, &reply) == CHANNEL_RC_OK);
  assert(requests == 2 && requested_id == CF_UNICODETEXT && c.clipboard_revision == 0);
  assert(clip_data(&clip, &reply) == CHANNEL_RC_OK);
  assert(c.remote_clipboard_len == sizeof(text) && memcmp(c.remote_clipboard, text, sizeof(text)) == 0);
  assert(requests == 3 && requested_id == formats[1].formatId && c.clipboard_revision == 1);

  // A local copy supersedes an older remote offer and its queued text.
  assert(clip_formats(&clip, &list) == CHANNEL_RC_OK);
  assert(requests == 3);
  assert(aterm_rdp_paste(&c, text, sizeof(text) - 2) == 1);
  reply.common.msgFlags = CB_RESPONSE_FAIL;
  assert(clip_data(&clip, &reply) == CHANNEL_RC_OK);
  assert(requests == 3 && c.clipboard_revision == 1);
  assert(clip_formats(&clip, &list) == CHANNEL_RC_OK);
  assert(requests == 4 && requested_id == CF_UNICODETEXT);

  free(c.remote_clipboard);
  free(c.local_clipboard);
  DeleteCriticalSection(&c.lock);
  puts("RDP clipboard format ordering passed");
  return 0;
}
