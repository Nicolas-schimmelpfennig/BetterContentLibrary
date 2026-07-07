import Foundation
import Supabase

/// Reads and writes the `folders` table. Org-scoped by RLS.
public final class FoldersService: Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    /// Lists the folders directly under `parent` (nil = top level), by name.
    public func list(parent: UUID?) async throws -> [Folder] {
        let base = client.from("folders").select()
        let filtered = parent.map { base.eq("parent_id", value: $0.uuidString) }
            ?? base.is("parent_id", value: nil)
        return try await filtered
            .order("name", ascending: true)
            .execute()
            .value
    }

    /// Lists every folder in the org (all nesting levels), by name — used to
    /// offer any folder as a move destination, not just the current one's children.
    public func listAll(orgId: UUID) async throws -> [Folder] {
        try await client
            .from("folders")
            .select()
            .eq("org_id", value: orgId.uuidString)
            .order("name", ascending: true)
            .execute()
            .value
    }

    public func create(name: String, orgId: UUID, parentId: UUID?) async throws -> Folder {
        let row = InsertFolder(org_id: orgId.uuidString, parent_id: parentId?.uuidString, name: name)
        return try await client
            .from("folders")
            .insert(row, returning: .representation)
            .select()
            .single()
            .execute()
            .value
    }

    public func rename(_ id: UUID, name: String) async throws {
        try await client
            .from("folders")
            .update(NamePatch(name: name))
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Deletes a folder. Child folders cascade; clips inside fall back to root
    /// (their `folder_id` is set null).
    public func delete(_ id: UUID) async throws {
        try await client
            .from("folders")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    private struct InsertFolder: Encodable, Sendable {
        let org_id: String
        let parent_id: String?
        let name: String
    }

    private struct NamePatch: Encodable, Sendable {
        let name: String
    }
}
