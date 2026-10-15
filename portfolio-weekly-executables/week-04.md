# Week 4 — iOS Foundation (Models & Project Setup)

Progress: 5/5 sessions (100%) ✅

iOS focus begins. Goal by Friday: the template is stripped, the project targets
iOS 18, the network DTOs and `ChatMessage` UI model exist, and the session
identifier is persisted in the Keychain.

_The original goal also listed a SwiftData model. Persistence moved to post-MVP
mid-week (see the note under Friday), so it is deliberately not part of this
week's scope._

## Mon, Aug 10 — Strip the template
- [x] Delete `Item.swift` and the SwiftData `Item` sample code.
- [x] Replace the list-based `ContentView` with an empty placeholder view.
- [x] Remove the CloudKit entitlement and `remote-notification` background mode
      (not needed for the chat app).
- **Done when:** the app builds and launches to a blank placeholder screen. ✅

## Tue, Aug 11 — Set deployment target + project structure
- [x] Set `IPHONEOS_DEPLOYMENT_TARGET` to 18.0.
- [x] Create folder groups: `Models`, `Services`, `ViewModels`, `Views`.
- **Done when:** the project builds against iOS 18 with the new group structure. ✅

## Wed, Aug 12 — Network DTOs
- [x] Add `Codable` request/response structs mirroring the Week 1 API contract.
- [x] Add the error-response DTO.
- **Done when:** DTOs compile and match the backend shapes exactly. ✅

## Thu, Aug 13 — UI model
- [x] Add a `ChatMessage` struct: `Identifiable`, `Equatable`, with role
      (user/assistant), text, and timestamp.
- [x] Keep it distinct from the network DTOs.
- **Done when:** `ChatMessage` compiles and is ready for `ForEach`. ✅

## Fri, Aug 14 — Keychain session manager _(pulled up from Week 5)_
- [x] Generate a session identifier once and persist it in the Keychain.
- [x] Expose a read accessor for the Week 5 service layer to attach to requests.
- **Done when:** the session id is generated on first launch and survives relaunch. ✅

_SwiftData message persistence was deferred to post-MVP (see `beyond-mvp.md` §5);
the Keychain manager moved up from Week 5 Wed to fill this slot._

## Notes / blockers
_(jot anything that tripped you up so we pick it up next session)_
