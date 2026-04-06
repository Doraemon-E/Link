//
//  ContentView.swift
//  link
//
//  Created by Doracmon on 2026/4/3.
//

import SwiftUI

struct ContentView: View {
    let dependencies: HomeDependencies

    var body: some View {
        HomeView(dependencies: dependencies)
    }
}
