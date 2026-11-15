#!/usr/bin/env python3
"""Dependency-free stdio adapter for Atermius's authenticated local MCP endpoint.

Set ATERMIUS_MCP_URL and ATERMIUS_MCP_TOKEN in the MCP client's environment.
Neither credentials nor protocol messages are logged to stderr.
"""
import ipaddress
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

MAX_LINE = 512 * 1024
MAX_RESPONSE = 2 * 1024 * 1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def allowed_host(host):
    """Loopback, or an IP literal on a private network (Atermius listening on the LAN).

    Host names other than localhost are refused: the listener rejects them too, and the
    token must never be sent to whatever a name happens to resolve to.
    """
    if host in ('127.0.0.1', 'localhost'):
        return True
    try:
        address = ipaddress.ip_address(host or '')
    except ValueError:
        return False
    mapped = getattr(address, 'ipv4_mapped', None)
    if mapped is not None:
        address = mapped
    return (address.is_loopback or address.is_private or address.is_link_local
            or address in ipaddress.ip_network('100.64.0.0/10')) and not address.is_unspecified


def main():
    url = os.environ.get('ATERMIUS_MCP_URL', 'http://127.0.0.1:8765/mcp')
    token = os.environ.get('ATERMIUS_MCP_TOKEN', '')
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'http' or not allowed_host(parsed.hostname)
            or parsed.path != '/mcp' or parsed.query or parsed.fragment or parsed.username
            or len(token) < 32 or any(ord(c) < 33 or ord(c) > 126 for c in token)):
        print('Configure the MCP URL (loopback, or the IP address of a device on a private '
              'network) and its current access token.', file=sys.stderr)
        return 2
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    while True:
        line = sys.stdin.buffer.readline(MAX_LINE + 1)
        if not line:
            return 0
        if len(line) > MAX_LINE:
            print('MCP input exceeded its size limit.', file=sys.stderr)
            return 2
        request_id = None
        try:
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError('object required')
            request_id = message.get('id')
            params = message.get('params') or {}
            meta = params.get('_meta') or {}
            version = meta.get('io.modelcontextprotocol/protocolVersion', '2025-11-25')
            headers = {'Content-Type': 'application/json',
                       'Accept': 'application/json, text/event-stream',
                       'Authorization': 'Bearer ' + token,
                       'MCP-Protocol-Version': version}
            if version == '2026-07-28':
                headers['Mcp-Method'] = message['method']
                if message['method'] in ('tools/call', 'prompts/get', 'resources/read'):
                    headers['Mcp-Name'] = params.get('name', params.get('uri', ''))
            request = urllib.request.Request(url, data=line, headers=headers, method='POST')
            try:
                response = opener.open(request, timeout=140)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                body = response.read(MAX_RESPONSE + 1)
            if len(body) > MAX_RESPONSE:
                raise ValueError('response too large')
            if body:
                decoded = json.loads(body)
                if request_id is not None:
                    sys.stdout.write(json.dumps(decoded, ensure_ascii=True) + '\n')
                    sys.stdout.flush()
            elif request_id is not None:
                raise ValueError('empty response')
        except Exception:
            if request_id is not None:
                sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': request_id,
                    'error': {'code': -32603, 'message': 'Local MCP request failed. Check that Atermius is unlocked and MCP is enabled with the current token. Do not automatically retry side effects.'}}) + '\n')
                sys.stdout.flush()
            else:
                print('Invalid or rejected MCP notification.', file=sys.stderr)


if __name__ == '__main__':
    sys.exit(main())
