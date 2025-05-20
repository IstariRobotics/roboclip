import Foundation
import Supabase
import SwiftUI

class AuthManager: NSObject, ObservableObject {
    @Published var isSignedIn: Bool = false
    @Published var userEmail: String? = nil
    @Published var supabaseSession: Session? = nil
    private let supabaseUrl: URL
    private let supabaseKey: String
    private let client: SupabaseClient

    override init() {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "https://rfprjaeyqomuvzempixf.supabase.co"
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        self.supabaseUrl = URL(string: urlString)!
        self.supabaseKey = key
        self.client = SupabaseClient(supabaseURL: supabaseUrl, supabaseKey: supabaseKey)
        super.init()
        self.supabaseSession = nil
        self.isSignedIn = false
        self.userEmail = nil
    }

    func signOut() {
        self.supabaseSession = nil
        self.isSignedIn = false
        self.userEmail = nil
        UserDefaults.standard.removeObject(forKey: "supabaseSession")
    }
}
