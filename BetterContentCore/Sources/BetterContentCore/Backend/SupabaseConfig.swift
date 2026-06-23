import Foundation

/// Connection details for the BetterContentLibrary Supabase project.
///
/// The publishable key is safe to ship in the client: it only grants the
/// permissions allowed by Row-Level Security. Secret keys (service_role) never
/// live here — they belong in server-side Edge Function secrets.
public enum SupabaseConfig {
    public static let url = URL(string: "https://srltmrcwpdtjiiflwwkb.supabase.co")!
    public static let publishableKey = "sb_publishable_MFWkSkY2G340V9LSBj4j_Q_TOKsnRW3"
}
