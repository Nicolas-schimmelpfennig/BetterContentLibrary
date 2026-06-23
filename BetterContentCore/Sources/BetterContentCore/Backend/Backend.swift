import Foundation
import Supabase

/// The shared Supabase client used across the macOS and iOS apps.
public enum Backend {
    public static let client = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.publishableKey
    )
}
