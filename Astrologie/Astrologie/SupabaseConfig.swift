import Foundation

/// Connection details for the Supabase project backing the astrology chat.
///
/// The publishable key is safe to ship in the client: it only identifies the
/// project. Actual access is governed by Row Level Security policies and by
/// the auth configuration of each edge function.
nonisolated enum SupabaseConfig {
    static let projectURL = URL(string: "https://dpmzorjfuzfpxthyqiyg.supabase.co")!

    /// New-format publishable key (`sb_publishable_…`). Sent in the `apikey`
    /// header — it is not a JWT, so it must not be sent as a bearer token.
    static let publishableKey = "sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6"

    /// Endpoint for the `chat` edge function.
    static var chatFunctionURL: URL {
        projectURL.appendingPathComponent("functions/v1/chat")
    }
}
