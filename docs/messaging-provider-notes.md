# Messaging provider notes

## Resend

The official Send Email API requires `from`, `to`, and `subject`; it accepts HTML/text or a published template, supports attachments, and supports an `Idempotency-Key` header with a 24-hour lifetime. The adapter will use environment variables only and will keep provider IDs in MessageLog.

Source: https://resend.com/docs/api-reference/emails/send-email

## Meta WhatsApp Business Cloud API

Meta's official WhatsApp webhook documentation says the `messages` webhook carries inbound messages and outgoing delivery/read status updates. Payloads may be retried, so webhook handling must be idempotent. Meta's service-message documentation states that free-form messages are allowed only during the 24-hour customer service window; outside it, only approved templates may be sent. Meta's template documentation states that template strings are not translated by Meta, template languages must be supplied separately, and only approved templates can be sent. The send API response means the request was accepted, not that delivery succeeded; delivery status arrives by webhook.

Sources:
- https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview
- https://developers.facebook.com/documentation/business-messaging/whatsapp/templates/overview
- https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/send-messages
