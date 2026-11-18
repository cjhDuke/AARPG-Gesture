"""Bound JSON requests before parsing, including clients with dishonest lengths."""
from fastapi.responses import JSONResponse

ACCOUNT_BODY_LIMIT = 8192
CLOUD_BODY_LIMIT = 80 * 1024


class RequestLimits:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] not in ("POST", "PUT", "PATCH", "DELETE"):
            return await self.app(scope, receive, send)
        headers = dict(scope["headers"])
        length = headers.get(b"content-length", b"")
        path = scope.get("path", "")
        cloud_upload = scope["method"] == "PUT" and path.startswith("/api/v1/saves/")
        limit = CLOUD_BODY_LIMIT if cloud_upload else ACCOUNT_BODY_LIMIT

        async def reject(status, message):
            response = JSONResponse({"error": {"code": "invalid_request", "message": message}}, status_code=status,
                                    headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})
            await response(scope, receive, send)

        if not length.isdigit() or len(length) > 8 or int(length) > limit:
            return await reject(413, "Request is too large or has no Content-Length.")
        if headers.get(b"content-type", b"").split(b";")[0].lower() != b"application/json":
            return await reject(415, "JSON is required.")
        content = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            if message["type"] != "http.request":
                continue
            chunk = message.get("body", b"")
            if len(content) + len(chunk) > limit:
                return await reject(413, "Request is too large.")
            content.extend(chunk)
            if not message.get("more_body", False):
                break
        if len(content) != int(length):
            return await reject(400, "Content-Length does not match the request.")
        buffered = bytes(content)
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": buffered, "more_body": False}
            return await receive()

        await self.app(scope, replay, send)
