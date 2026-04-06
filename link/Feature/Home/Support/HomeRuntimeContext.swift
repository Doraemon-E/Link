//
//  HomeRuntimeContext.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation
import SwiftData

@MainActor
struct HomeRuntimeContext {
    let modelContext: ModelContext
    let sessions: [ChatSession]

    var historySessions: [ChatSession] {
        sessions.filter(\.hasMessages)
    }
}
