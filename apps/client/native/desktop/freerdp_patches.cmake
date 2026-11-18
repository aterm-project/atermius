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

# 5. Keep the Windows version a server states in the NTLM challenge of NLA
#    (MS-NLMP 2.2.1.2: NegotiateFlags at 20, Version at 48), so a Host can
#    show its system. Works with WinPR's NTLM and with native SSPI alike: the
#    token is read before either consumes it, also inside SPNEGO. A challenge
#    without a target type is ignored: FreeRDP-based servers (GNOME Remote
#    Desktop and others) state a fixed Windows version but never set one.
#    Read once per connect on the connecting thread.
atermius_patch(libfreerdp/core/nla.c
  "WINPR_ATTR_NODISCARD\nstatic int nla_client_recv_nego_token(rdpNla* nla)\n{\n\tcredssp_auth_take_input_buffer(nla->auth, &nla->negoToken);"
  "/* atermius: system version from the server's NTLM challenge, 0 if none */\nstatic WINPR_TLS UINT32 atermius_ntlm_server_os = 0;\n\nUINT32 atermius_take_ntlm_server_os(void);\nUINT32 atermius_take_ntlm_server_os(void)\n{\n\tconst UINT32 value = atermius_ntlm_server_os;\n\tatermius_ntlm_server_os = 0;\n\treturn value;\n}\n\nstatic void atermius_note_ntlm_challenge(const SecBuffer* token)\n{\n\tstatic const BYTE signature[12] = { 0x4E, 0x54, 0x4C, 0x4D, 0x53, 0x53, 0x50, 0, 2, 0, 0, 0 };\n\tconst BYTE* data = (const BYTE*)token->pvBuffer;\n\tconst size_t length = token->cbBuffer;\n\n\tif (!data)\n\t\treturn;\n\n\tfor (size_t i = 0; i + 56 <= length; i++)\n\t{\n\t\tconst BYTE* m = &data[i];\n\n\t\tif (memcmp(m, signature, sizeof(signature)) != 0)\n\t\t\tcontinue;\n\n\t\tconst UINT32 flags = (UINT32)m[20] | ((UINT32)m[21] << 8) | ((UINT32)m[22] << 16) |\n\t\t                     ((UINT32)m[23] << 24);\n\n\t\t/* NEGOTIATE_VERSION, a target type, NTLM revision 15, a real build */\n\t\tif ((flags & 0x02000000) && (flags & 0x00030000) && (m[55] == 0x0F) && (m[48] >= 5) &&\n\t\t    ((m[50] | m[51]) != 0))\n\t\t\tatermius_ntlm_server_os = ((UINT32)m[48] << 24) | ((UINT32)m[49] << 16) |\n\t\t\t                          ((UINT32)m[51] << 8) | (UINT32)m[50];\n\t\treturn;\n\t}\n}\n\nWINPR_ATTR_NODISCARD\nstatic int nla_client_recv_nego_token(rdpNla* nla)\n{\n\tatermius_note_ntlm_challenge(&nla->negoToken);\n\tcredssp_auth_take_input_buffer(nla->auth, &nla->negoToken);")
