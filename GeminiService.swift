import Foundation
import Cocoa

// MARK: - Gemini Service (API Key Auth)

final class GeminiService {
    
    // MARK: - Constants
    
    private let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    
    private let naviDir: URL
    private let apiKeyFile: URL
    
    // MARK: - State
    
    private var apiKey: String?
    
    // MARK: - Init
    
    init() {
        naviDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".navi")
        apiKeyFile = naviDir.appendingPathComponent(".api_key")
        
        loadAPIKey()
    }
    
    // MARK: - Public Interface
    
    var isAuthenticated: Bool {
        return apiKey != nil && !(apiKey?.isEmpty ?? true)
    }
    
    /// Send a prompt to Gemini and get a text response
    func generateContent(prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let key = apiKey, !key.isEmpty else {
            completion(.failure(GeminiError.notAuthenticated))
            return
        }
        
        let urlString = "\(geminiBaseURL)?key=\(key)"
        guard let url = URL(string: urlString) else {
            completion(.failure(GeminiError.apiError("Invalid URL")))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ]
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(GeminiError.noData)) }
                return
            }
            
            // Parse response
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let first = candidates.first,
                   let content = first["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let text = parts.first?["text"] as? String {
                    DispatchQueue.main.async { completion(.success(text)) }
                } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let error = json["error"] as? [String: Any],
                          let message = error["message"] as? String {
                    DispatchQueue.main.async { completion(.failure(GeminiError.apiError(message))) }
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "Unknown"
                    DispatchQueue.main.async { completion(.failure(GeminiError.apiError("Unexpected: \(raw)"))) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }
    
    // MARK: - Persistence
    
    private func loadAPIKey() {
        // Try reading from ~/.navi/.api_key (plain text, one line)
        guard let data = try? String(contentsOf: apiKeyFile, encoding: .utf8) else {
            print("⚠️ No API key found at \(apiKeyFile.path)")
            print("   Create one at https://aistudio.google.com/apikey")
            print("   Then save it: echo 'YOUR_KEY' > ~/.navi/.api_key")
            return
        }
        
        let key = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            apiKey = key
            print("✅ Loaded Gemini API key")
        }
    }
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case notAuthenticated
    case tokenRefreshFailed
    case noData
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "No API key — save your key to ~/.navi/.api_key"
        case .tokenRefreshFailed: return "Token refresh failed"
        case .noData: return "No response from Gemini"
        case .apiError(let msg): return msg
        }
    }
}
