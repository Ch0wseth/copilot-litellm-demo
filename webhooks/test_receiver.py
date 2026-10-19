"""Focused receiver tests, using an ephemeral loopback HTTP server."""

import hashlib
import hmac
from http.client import HTTPConnection
import json
import threading
import unittest
import uuid

from receiver import MAX_BODY_BYTES, MAX_DELIVERIES, Receiver


class ReceiverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.secret = b"a" * 64
        cls.server = Receiver(("127.0.0.1", 0), cls.secret)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.server.deliveries.clear()

    def request(self, method, path, body=None, headers=None):
        connection = HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def signed_headers(self, body, delivery=None):
        return {
            "Content-Type": "application/json",
            "X-Hub-Signature-256": "sha256=" + hmac.new(self.secret, body, hashlib.sha256).hexdigest(),
            "X-GitHub-Event": "workflow_run",
            "X-GitHub-Delivery": delivery or str(uuid.uuid4()),
        }

    def test_accepts_raw_body_without_retaining_payload_and_deduplicates(self):
        body = b' { "action": "completed", "private_payload": "do not retain" } '
        headers = self.signed_headers(body)
        status, result = self.request("POST", "/webhook", body, headers)
        self.assertEqual((status, result["status"]), (202, "accepted"))
        status, result = self.request("POST", "/webhook", body, headers)
        self.assertEqual((status, result["status"]), (200, "duplicate"))
        _, records = self.request("GET", "/deliveries")
        self.assertEqual(len(records), 1)
        self.assertTrue(records[0]["signature_verified"])
        self.assertEqual(records[0]["event"], "workflow_run")
        self.assertNotIn("private_payload", json.dumps(records))
        self.assertNotIn("do not retain", json.dumps(records))

    def test_tampered_missing_and_wrong_signatures_are_not_stored(self):
        body = b'{"action":"completed"}'
        headers = self.signed_headers(body)
        for signature in ("", "sha256=" + "0" * 64, headers["X-Hub-Signature-256"]):
            headers["X-Hub-Signature-256"] = signature
            status, _ = self.request("POST", "/webhook", b'{"action":"edited"}', headers)
            self.assertEqual(status, 401)
        self.assertEqual(len(self.server.deliveries), 0)

    def test_invalid_signed_json_headers_and_size_are_rejected(self):
        for body in (b"{", b"[]", b'{"action":42}'):
            with self.subTest(body=body):
                self.assertEqual(self.request("POST", "/webhook", body, self.signed_headers(body))[0], 400)
        body = b"{}"
        headers = self.signed_headers(body)
        headers["X-GitHub-Event"] = "<script>"
        self.assertEqual(self.request("POST", "/webhook", body, headers)[0], 400)
        headers = self.signed_headers(body)
        headers["Content-Length"] = str(MAX_BODY_BYTES + 1)
        self.assertEqual(self.request("POST", "/webhook", body, headers)[0], 413)
        self.assertEqual(len(self.server.deliveries), 0)

    def test_only_webhook_route_accepts_posts(self):
        body = b"{}"
        self.assertEqual(self.request("POST", "/deliveries", body, self.signed_headers(body))[0], 404)

    def test_delivery_memory_is_bounded(self):
        for index in range(MAX_DELIVERIES):
            self.server.deliveries[str(index)] = {"delivery_id": str(index)}
        body = b"{}"
        self.assertEqual(self.request("POST", "/webhook", body, self.signed_headers(body))[0], 202)
        self.assertEqual(len(self.server.deliveries), MAX_DELIVERIES)
        self.assertNotIn("0", self.server.deliveries)


if __name__ == "__main__":
    unittest.main()
