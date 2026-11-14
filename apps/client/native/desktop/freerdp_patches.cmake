# Small, auditable FreeRDP 3.33.0 source patches, applied once to the pinned
# tarball (see CMakeLists.txt PATCH_COMMAND). Each patch is idempotent and
# fails loudly if upstream text changed.
if(NOT FREERDP_SOURCE)
  message(FATAL_ERROR "FREERDP_SOURCE is required")
endif()

function(atermius_patch file old new)
  set(path "${FREERDP_SOURCE}/${file}")
  file(READ "${path}" code)
  string(FIND "${code}" "${new}" already)
  if(NOT already EQUAL -1)
    return()
  endif()
  string(FIND "${code}" "${old}" found)
  if(found EQUAL -1)
    message(FATAL_ERROR "FreeRDP ${file} changed; review the Atermius patch")
  endif()
  string(REPLACE "${old}" "${new}" code "${code}")
  file(WRITE "${path}" "${code}")
endfunction()

# 1. rdpecam on Windows: no V4L requirement. The capture HAL is provided by
#    atermius_rdp (camera_mf.c, Media Foundation) through the addin provider.
atermius_patch(channels/rdpecam/client/CMakeLists.txt
  "if(NOT ANDROID AND NOT APPLE)\n  find_package(V4L)"
  "if(NOT ANDROID AND NOT APPLE AND NOT WIN32)\n  find_package(V4L)")

# 2. rdpecam passthrough without FFmpeg. When the camera already produces the
#    negotiated format (MJPG/YUY2/NV12...), samples are copied unchanged, which
#    FreeRDP's own converter also does. Only the unused codec context setup
#    required FFmpeg; skip it for passthrough.
atermius_patch(channels/rdpecam/client/encoding.c
  "BOOL ecam_encoder_context_init(CameraDeviceStream* stream)\n{\n\tif (!ecam_init_video_context(stream))\n\t\treturn FALSE;"
  "BOOL ecam_encoder_context_init(CameraDeviceStream* stream)\n{\n\t/* atermius: raw/MJPG passthrough needs no codec context */\n\tif ((ecamToVideoFormat(streamInputFormat(stream)) != FREERDP_VIDEO_FORMAT_NONE) &&\n\t    (streamInputFormat(stream) == streamOutputFormat(stream)))\n\t\treturn TRUE;\n\n\tif (!ecam_init_video_context(stream))\n\t\treturn FALSE;")
atermius_patch(channels/rdpecam/client/encoding.c
  "\tif (!ecam_encoder_context_init(stream))\n\t\treturn FALSE;\n\n\treturn freerdp_video_sample_convert("
  "\tif (!ecam_encoder_context_init(stream))\n\t\treturn FALSE;\n\n\t/* atermius: passthrough without a codec context */\n\tif ((inputFormat != FREERDP_VIDEO_FORMAT_NONE) && (inputFormat == outputFormat))\n\t{\n\t\tif (!Stream_EnsureRemainingCapacity(output, srcSize))\n\t\t\treturn FALSE;\n\t\tStream_Write(output, srcData, srcSize);\n\t\treturn TRUE;\n\t}\n\n\treturn freerdp_video_sample_convert(")

# 3. POSIX directory enumeration omits . and ..: an empty directory has no
#    FindFirstFile result. It must still be removed (RDPDR DeleteDirectory).
atermius_patch(winpr/libwinpr/path/path.c
  "\t\tdir = FindFirstFileA(path_slash, &findFileData);\n\n\t\tif (dir == INVALID_HANDLE_VALUE)\n\t\t\tgoto fail;"
  "\t\tdir = FindFirstFileA(path_slash, &findFileData);\n\n\t\tif (dir == INVALID_HANDLE_VALUE)\n\t\t{\n\t\t\tconst DWORD error = GetLastError();\n\t\t\tif ((error == ERROR_NO_MORE_FILES) || (error == ERROR_FILE_NOT_FOUND))\n\t\t\t\tret = winpr_RemoveDirectory(lpPathName);\n\t\t\tgoto fail;\n\t\t}")

# 4. Report native touch only after the server SC_READY and our CS_READY.
#    ChannelConnected precedes that handshake; GetVersion is initialized to
#    V300 even before negotiation, so it cannot be used as a readiness flag.
atermius_patch(include/freerdp/client/rdpei.h
  "\t\tUINT32 clientFeaturesMask;"
  "\t\tUINT32 clientFeaturesMask;\n\t\t/* atermius: optional callback after the RDPEI ready handshake */\n\t\tpcRdpeiResumeTouch Ready;")
atermius_patch(channels/rdpei/client/rdpei_main.c
  "\t\t\tbreak;\n\n\t\tcase EVENTID_SUSPEND_TOUCH:"
  "\t\t\t/* atermius: both ready PDUs succeeded */\n\t\t\tIFCALLRET(rdpei->context->Ready, error, rdpei->context);\n\t\t\tif (error)\n\t\t\t\treturn error;\n\t\t\tbreak;\n\n\t\tcase EVENTID_SUSPEND_TOUCH:")

# 5. Android playback (rdpsnd "opensles") must neither abort the app nor end the
#    session. Upstream WINPR_ASSERTs every OpenSL ES result (verbose asserts
#    abort the process), and a failed Open or SetVolume becomes a channel error
#    that disconnects (rdpsnd_main.c). A player that does not open is logged and
#    leaves a silent device: Play drops the waves, which rdpsnd still confirms,
#    and the next format change opens it again. Waves the 16-bit player cannot
#    take (empty, odd size) are dropped.
atermius_patch(channels/rdpsnd/client/opensles/opensl_io.c
  "WINPR_ASSERT(!result);"
  "(void)result; /* atermius: the result is returned, not asserted */")
atermius_patch(channels/rdpsnd/client/opensles/rdpsnd_opensles.c
  "\topensles->stream = android_OpenAudioDevice(opensles->rate, opensles->channels, 20);\n\tWINPR_ASSERT(opensles->stream);\n\n\tif (!opensles->stream)\n\t\tWLog_ERR(TAG, \"android_OpenAudioDevice failed\");\n\telse\n\t\trdpsnd_opensles_set_volume(device, opensles->volume);\n\n\treturn rdpsnd_opensles_set_format(device, format, latency);\n}"
  "\t/* atermius: store the format (without a stream, set_format opens nothing), open the\n\t * player once at its rate and channels, and stay silent if it does not open */\n\t(void)rdpsnd_opensles_set_format(device, format, latency);\n\topensles->stream = android_OpenAudioDevice(opensles->rate, opensles->channels, 20);\n\tif (!opensles->stream)\n\t\tWLog_ERR(TAG, \"android_OpenAudioDevice failed (%\" PRIu32 \" Hz, %\" PRIu32 \" channels), no sound\",\n\t\t         opensles->rate, opensles->channels);\n\telse\n\t\t(void)rdpsnd_opensles_set_volume(device, opensles->volume);\n\n\treturn TRUE;\n}")
atermius_patch(channels/rdpsnd/client/opensles/rdpsnd_opensles.c
  "\tif (opensles->stream)\n\t{\n\t\tif (0 == opensles->volume)\n\t\t\treturn android_SetOutputMute(opensles->stream, true);\n\t\telse\n\t\t{\n\t\t\tconst int max = android_GetOutputVolumeMax(opensles->stream);\n\t\t\tconst int vol = rdpsnd_opensles_volume_to_millibel(value & 0xFFFF, max);\n\n\t\t\tif (!android_SetOutputMute(opensles->stream, false))\n\t\t\t\treturn FALSE;\n\n\t\t\tif (!android_SetOutputVolume(opensles->stream, vol))\n\t\t\t\treturn FALSE;\n\t\t}\n\t}\n\n\treturn TRUE;"
  "\t/* atermius: a volume the player refuses is logged, not returned as a failure */\n\tif (opensles->stream)\n\t{\n\t\tBOOL applied = FALSE;\n\t\tif (0 == opensles->volume)\n\t\t\tapplied = android_SetOutputMute(opensles->stream, true);\n\t\telse\n\t\t{\n\t\t\tconst int max = android_GetOutputVolumeMax(opensles->stream);\n\t\t\tconst int vol = rdpsnd_opensles_volume_to_millibel(value & 0xFFFF, max);\n\n\t\t\tapplied = android_SetOutputMute(opensles->stream, false) &&\n\t\t\t          android_SetOutputVolume(opensles->stream, vol);\n\t\t}\n\t\tif (!applied)\n\t\t\tWLog_WARN(TAG, \"volume 0x%08\" PRIx32 \" not applied\", value);\n\t}\n\n\treturn TRUE;")
atermius_patch(channels/rdpsnd/client/opensles/rdpsnd_opensles.c
  "\tWINPR_ASSERT(0 == size % 2);\n\tWINPR_ASSERT(size > 0);\n\tWINPR_ASSERT(src.b);\n\tret = android_AudioOut(opensles->stream, src.s, size / 2);"
  "\t/* atermius: the size comes from the server; drop what the 16-bit player cannot take */\n\tif (!src.b || (size < 2) || ((size % 2) != 0) || (size / 2 > INT32_MAX))\n\t{\n\t\tWLog_DBG(TAG, \"dropped a wave of %\" PRIuz \" bytes\", size);\n\t\treturn 0;\n\t}\n\tret = android_AudioOut(opensles->stream, src.s, (int)(size / 2));")

# 6. The microphone (audin "opensles") must not end the session either. A
#    recorder that does not open (no RECORD_AUDIO permission, input busy) is
#    reported in the Open Reply PDU ([MS-RDPEAI] 2.2.2.4, Result) and the channel
#    stays, so the server may open it again later; upstream returned an error
#    that drops the channel. The recorder starts inside android_OpenRecDevice,
#    so its callback target is set first, and it is destroyed before the
#    buffers it fills are freed.
atermius_patch(channels/audin/client/audin_main.c
  "\tif (!audin_open_device(audin, callback))\n\t{\n\t\taudin->format = nullptr;\n\t\treturn ERROR_INTERNAL_ERROR;\n\t}\n\n\tif ((error = audin_send_format_change_pdu(audin, callback, initialFormat)))"
  "\tif (!audin_open_device(audin, callback))\n\t{\n\t\t/* atermius: answer with a failure Result and keep the channel and the session */\n\t\tWLog_Print(audin->log, WLOG_ERROR, \"microphone not opened, the session continues without it\");\n\t\taudin->format = nullptr;\n\t\treturn audin_send_open_reply_pdu(audin, callback, 0x80004005 /* E_FAIL */);\n\t}\n\n\tif ((error = audin_send_format_change_pdu(audin, callback, initialFormat)))")
atermius_patch(channels/audin/client/audin_main.c
  "\t\tif (!audin_open_device(audin, callback))\n\t\t{\n\t\t\taudin->format = nullptr;\n\t\t\treturn ERROR_INTERNAL_ERROR;\n\t\t}"
  "\t\tif (!audin_open_device(audin, callback))\n\t\t{\n\t\t\t/* atermius: as for Open, the session continues without the microphone */\n\t\t\tWLog_Print(audin->log, WLOG_ERROR, \"microphone not reopened, the session continues without it\");\n\t\t\taudin->format = nullptr;\n\t\t\treturn CHANNEL_RC_OK;\n\t\t}")
atermius_patch(channels/audin/client/opensles/audin_opensl_es.c
  "\tif (!(opensles->stream = android_OpenRecDevice("
  "\t/* atermius: recording starts inside android_OpenRecDevice, whose first buffer can\n\t * come back before it returns */\n\topensles->receive = receive;\n\topensles->user_data = user_data;\n\n\tif (!(opensles->stream = android_OpenRecDevice(")
atermius_patch(channels/audin/client/opensles/opensl_io.c
  "\topensles_queue_element_free(p->next);\n\topensles_queue_element_free(p->prep);\n\topenSLDestroyEngine(p);"
  "\t/* atermius: destroy the recorder (no callback runs after that) before its buffers */\n\topenSLDestroyEngine(p);\n\topensles_queue_element_free(p->next);\n\topensles_queue_element_free(p->prep);")

# 7. MediaCodec (WITH_MEDIACODEC, the Android camera) is an encoder only here.
#    With it FreeRDP turns WITH_GFX_H264 on, and connecting prepares every codec
#    (libfreerdp/core/connection.c), which would create and start a hardware
#    H.264 decoder in each session. The engine never negotiates the graphics
#    pipeline (SupportGraphicsPipeline=FALSE, rdpgfx not built), so the decoder
#    role is refused: libfreerdp/core/codecs.c logs a warning and keeps no H.264
#    context.
atermius_patch(libfreerdp/codec/h264_mediacodec.c
  "\tWLog_Print(h264->log, WLOG_DEBUG, \"Initializing MediaCodec\");\n"
  "\t/* atermius: encoder only (camera); there is no graphics pipeline to decode for */\n\tif (!h264->Compressor)\n\t\treturn FALSE;\n\n\tWLog_Print(h264->log, WLOG_DEBUG, \"Initializing MediaCodec\");\n")

# 8. No MediaCodec AAC. WITH_MEDIACODEC also builds dsp_mediacodec.c, with which
#    rdpsnd offers AAC for playback and audin for the microphone, so a server
#    would move the session audio onto that experimental codec. Audio keeps
#    the built-in PCM of every other Atermius engine (ATERMIUS_MEDIACODEC_AAC
#    is never defined).
atermius_patch(libfreerdp/codec/CMakeLists.txt
  "list(APPEND CODEC_SRCS h264_mediacodec.c dsp_mediacodec.c)"
  "list(APPEND CODEC_SRCS h264_mediacodec.c) # atermius: no dsp_mediacodec.c (AAC)")
atermius_patch(libfreerdp/codec/dsp.c
  "#if defined(WITH_MEDIACODEC)"
  "#if defined(WITH_MEDIACODEC) && defined(ATERMIUS_MEDIACODEC_AAC)")
