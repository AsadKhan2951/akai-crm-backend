# Phase 22 external integration notes

- Meta WhatsApp Cloud API supports webhooks for inbound messages and status events: https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/overview
- Meta's official Cloud API getting-started documentation describes registering a webhook endpoint: https://developers.facebook.com/documentation/business-messaging/whatsapp/get-started
- Meta's official Messages API documentation distinguishes service messages sent inside the customer-service window: https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/send-messages
- Phase 22 therefore keeps the existing signed webhook, deduplicates external events, stores every message in `message_logs`, and uses free-form text only for an active inbound window. Outside the window, outbound messages must use an approved provider template.

The project is currently not connected to a Meta or WhatsApp connector. Credentials remain environment-only and are not requested or stored in the repository.
