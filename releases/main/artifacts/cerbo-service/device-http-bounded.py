#!/usr/bin/env python3
"""Small bounded HTTP client for the two local non-Victron devices.

Node-RED's core HTTP Request node buffers the complete response before a
downstream Function can inspect it.  On the memory-constrained Cerbo that is
too late for a useful limit.  This helper parses HTTP/1.1 directly and never
holds more than the fixed header/body limits below.
"""

from __future__ import annotations

import ipaddress
import json
import socket
import sys
import urllib.parse
from dataclasses import dataclass


MAX_HEADER_BYTES = 16 * 1024
MAX_BODY_BYTES = 64 * 1024
READ_CHUNK_BYTES = 4096
SOCKET_TIMEOUT_SECONDS = 8.0
MAX_CHUNK_LINE_BYTES = 128


class BoundedHttpError(Exception):
    """Base class for a rejected or failed local HTTP response."""


class ResponseTooLarge(BoundedHttpError):
    """The peer exceeded a fixed transport limit."""


class ProtocolError(BoundedHttpError):
    """The peer returned malformed or unsupported HTTP."""


@dataclass(frozen=True)
class Response:
    status: int
    body: bytes


class _Reader:
    def __init__(self, connection: socket.socket, initial: bytes = b"") -> None:
        self._connection = connection
        self._pending = bytearray(initial)

    def _receive(self) -> bool:
        chunk = self._connection.recv(READ_CHUNK_BYTES)
        if not chunk:
            return False
        self._pending.extend(chunk)
        return True

    def exact(self, size: int) -> bytes:
        if size < 0:
            raise ProtocolError("negative read size")
        while len(self._pending) < size:
            if not self._receive():
                raise ProtocolError("unexpected end of response")
        result = bytes(self._pending[:size])
        del self._pending[:size]
        return result

    def line(self, maximum: int) -> bytes:
        while True:
            marker = self._pending.find(b"\r\n")
            if marker >= 0:
                if marker > maximum:
                    raise ProtocolError("chunk line too long")
                result = bytes(self._pending[:marker])
                del self._pending[: marker + 2]
                return result
            if len(self._pending) > maximum:
                raise ProtocolError("chunk line too long")
            if not self._receive():
                raise ProtocolError("unexpected end of chunk line")

    def until_eof(self, maximum: int) -> bytes:
        result = bytearray()
        if self._pending:
            result.extend(self._pending)
            self._pending.clear()
        if len(result) > maximum:
            raise ResponseTooLarge("response body exceeds 64 KiB")
        while True:
            chunk = self._connection.recv(min(READ_CHUNK_BYTES, maximum + 1 - len(result)))
            if not chunk:
                return bytes(result)
            result.extend(chunk)
            if len(result) > maximum:
                raise ResponseTooLarge("response body exceeds 64 KiB")


def _read_headers(connection: socket.socket) -> tuple[int, dict[str, str], bytes]:
    received = bytearray()
    while True:
        marker = received.find(b"\r\n\r\n")
        if marker >= 0:
            header_end = marker + 4
            break
        if len(received) > MAX_HEADER_BYTES:
            raise ResponseTooLarge("response headers exceed 16 KiB")
        chunk = connection.recv(READ_CHUNK_BYTES)
        if not chunk:
            raise ProtocolError("response ended before headers")
        received.extend(chunk)
        if len(received) > MAX_HEADER_BYTES + READ_CHUNK_BYTES:
            raise ResponseTooLarge("response headers exceed 16 KiB")
    if header_end > MAX_HEADER_BYTES:
        raise ResponseTooLarge("response headers exceed 16 KiB")

    try:
        lines = received[:marker].decode("iso-8859-1").split("\r\n")
        version, status_text, _reason = (lines[0].split(" ", 2) + [""])[:3]
        status = int(status_text)
    except (UnicodeDecodeError, ValueError) as error:
        raise ProtocolError("invalid HTTP status line") from error
    if version not in ("HTTP/1.0", "HTTP/1.1") or status < 100 or status > 599:
        raise ProtocolError("unsupported HTTP status line")

    headers: dict[str, str] = {}
    for raw_line in lines[1:]:
        if not raw_line or ":" not in raw_line:
            raise ProtocolError("invalid HTTP header")
        key, value = raw_line.split(":", 1)
        key = key.strip().lower()
        value = value.strip()
        if not key or key in headers:
            raise ProtocolError("duplicate or empty HTTP header")
        headers[key] = value
    return status, headers, bytes(received[header_end:])


def _read_chunked(reader: _Reader) -> bytes:
    result = bytearray()
    while True:
        raw_size = reader.line(MAX_CHUNK_LINE_BYTES).split(b";", 1)[0].strip()
        try:
            chunk_size = int(raw_size, 16)
        except ValueError as error:
            raise ProtocolError("invalid chunk size") from error
        if chunk_size < 0:
            raise ProtocolError("negative chunk size")
        if chunk_size == 0:
            return bytes(result)
        if chunk_size > MAX_BODY_BYTES - len(result):
            raise ResponseTooLarge("response body exceeds 64 KiB")
        result.extend(reader.exact(chunk_size))
        if reader.exact(2) != b"\r\n":
            raise ProtocolError("invalid chunk terminator")


def bounded_http_request(
    host: str,
    port: int,
    method: str,
    path: str,
    *,
    timeout: float = SOCKET_TIMEOUT_SECONDS,
) -> Response:
    host_header = host if port == 80 else f"{host}:{port}"
    request = (
        f"{method} {path} HTTP/1.1\r\n"
        f"Host: {host_header}\r\n"
        "Accept: application/json\r\n"
        "Connection: close\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
    ).encode("ascii")
    with socket.create_connection((host, port), timeout=timeout) as connection:
        connection.settimeout(timeout)
        connection.sendall(request)
        status, headers, initial = _read_headers(connection)
        reader = _Reader(connection, initial)
        transfer_encoding = headers.get("transfer-encoding", "").lower()
        content_length = headers.get("content-length")
        if transfer_encoding:
            if transfer_encoding != "chunked":
                raise ProtocolError("unsupported transfer encoding")
            body = _read_chunked(reader)
        elif content_length is not None:
            try:
                length = int(content_length)
            except ValueError as error:
                raise ProtocolError("invalid content length") from error
            if length < 0:
                raise ProtocolError("negative content length")
            if length > MAX_BODY_BYTES:
                raise ResponseTooLarge("response body exceeds 64 KiB")
            body = reader.exact(length)
        else:
            body = reader.until_eof(MAX_BODY_BYTES)
    return Response(status=status, body=body)


def _rfc1918_address(raw: str) -> str:
    try:
        address = ipaddress.IPv4Address(raw)
    except ipaddress.AddressValueError as error:
        raise ValueError("invalid INDEVOLT IPv4 address") from error
    networks = (
        ipaddress.IPv4Network("10.0.0.0/8"),
        ipaddress.IPv4Network("172.16.0.0/12"),
        ipaddress.IPv4Network("192.168.0.0/16"),
    )
    if not any(address in network for network in networks):
        raise ValueError("INDEVOLT address is not RFC1918")
    return str(address)


def _target(arguments: list[str]) -> tuple[str, int, str, str]:
    if len(arguments) == 1 and arguments[0] == "vanturtle":
        return "vanturtle-fan.local", 80, "GET", "/state"
    if len(arguments) == 2 and arguments[0] == "indevolt":
        address = _rfc1918_address(arguments[1])
        points = [0, 7101, 6001, 6002, 6000, 1501, 1664, 1665, 2101, 2108]
        query = urllib.parse.urlencode(
            {"config": json.dumps({"t": points}, separators=(",", ":"))}
        )
        return address, 8080, "POST", f"/rpc/Indevolt.GetData?{query}"
    raise ValueError("usage: device-http-bounded.py vanturtle | indevolt RFC1918_IP")


def main(arguments: list[str]) -> int:
    try:
        host, port, method, path = _target(arguments)
        response = bounded_http_request(host, port, method, path)
        if response.status < 200 or response.status >= 300:
            print(f"device-http: HTTP {response.status}", file=sys.stderr)
            return 70
        sys.stdout.buffer.write(response.body)
        return 0
    except ResponseTooLarge as error:
        print(f"device-http: {error}", file=sys.stderr)
        return 65
    except (ProtocolError, OSError, socket.timeout) as error:
        print(f"device-http: {str(error)[:160]}", file=sys.stderr)
        return 69
    except ValueError as error:
        print(f"device-http: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
