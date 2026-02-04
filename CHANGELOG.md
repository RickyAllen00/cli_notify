# Changelog

All notable changes to this project will be documented in this file.
This project follows Semantic Versioning.

## 0.1.4
- Fix Telegram reply continuation in topic/thread chats (message_thread_id).
- Improve reply context fallback when Telegram reply metadata is missing.
- Fix bridge launching arguments to prevent prompt truncation.

## 0.1.3
- Improve remote image upload guidance when scp/pscp is missing.

## 0.1.2
- Support Telegram image replies for remote sessions (auto upload).

## 0.1.1
- Add Telegram reply-to-continue for latest session (text/image).

## 0.1.0
- Add EXE installer builder and GUI setup wizard.
- Add GUI configuration entry from tray.
- Add remote server (Linux) batch setup in installer (up to 5 hosts).
- Add Telegram setup help and improved onboarding flow.
