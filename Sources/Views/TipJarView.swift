import StoreKit
import SwiftUI

@MainActor
struct TipJarView: View {
    @Environment(MusicAppModel.self) private var model
    let tips: TipJarService

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "heart")
                        .appFont(.title3)
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                    Text("An optional tip helps me keep improving Breezy. Tips are one-time purchases through Apple and unlock no features or music.")
                        .appFont(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("tipJar.explanation")
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(AppTheme.surface)

            Section {
                if tips.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading tips…")
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .accessibilityIdentifier("tipJar.loading")
                }
                ForEach(tips.products, id: \.id) { product in
                    tipRow(product)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                if let error = tips.loadError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error)
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("tipJar.loadError")
                        Button {
                            Task { await tips.loadProducts() }
                        } label: {
                            Text("Try again")
                                .appFont(.subheadline, weight: .medium)
                                .foregroundStyle(AppTheme.accent)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(tips.isLoading || tips.isPurchasing)
                        .accessibilityIdentifier("tipJar.retry")
                    }
                }
                if tips.tipCount > 0 {
                    Text(tips.tipCount == 1 ? "One tip recorded on this iPhone. Thank you."
                         : "\(tips.tipCount.formatted()) tips recorded on this iPhone. Thank you.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("tipJar.count")
                        .accessibilityValue(String(tips.tipCount))
                }
            }
            .listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 52)
        .tint(AppTheme.accent)
        .foregroundStyle(AppTheme.primaryText)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Support development")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("tipJar.view")
        .task { await tips.loadProducts() }
        // Pending stays inline so a later approval can present its own confirmation.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tips.state == .pending { pendingMessage }
        }
        .alert(purchaseMessage?.title ?? "", isPresented: Binding(
            get: { purchaseMessage != nil },
            set: { if !$0 { tips.dismissMessage() } }
        ), presenting: purchaseMessage) { _ in
            Button("OK") { tips.dismissMessage() }
        } message: { message in
            Text(message.body)
        }
    }

    private var pendingMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tip pending", systemImage: "clock")
                .appFont(.subheadline, weight: .semibold)
            Text("Your purchase is pending with Apple. It may need approval. You don't need to try again.")
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button { tips.dismissMessage() } label: {
                Text("Got it")
                    .appFont(.subheadline, weight: .medium)
                    .foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tipJar.dismissPending")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlass(in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tipJar.pending")
    }

    private var purchaseMessage: (title: String, body: String)? {
        switch tips.state {
        case .thanked:
            return ("Thank you", "Your tip helps me keep improving Breezy.")
        case .failed(let message):
            return ("Couldn't confirm tip", message)
        case .idle, .purchasing, .pending:
            return nil
        }
    }

    private func tipRow(_ product: Product) -> some View {
        Button {
            AppNavigationIntent.perform(in: model) { Task { await tips.purchase(product) } }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .appFont(.subheadline, weight: .medium)
                        .foregroundStyle(AppTheme.primaryText)
                    if !product.description.isEmpty {
                        Text(product.description)
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(product.displayPrice)
                    .appFont(.subheadline, weight: .semibold)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(AppTheme.accent)
                    .background(AppTheme.accent.opacity(0.12), in: Capsule())
                    .opacity(tips.state == .purchasing(product.id) ? 0 : 1)
                    .overlay {
                        if tips.state == .purchasing(product.id) {
                            ProgressView().accessibilityLabel("Confirming tip")
                        }
                    }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tips.canPurchase)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(product.id)
    }
}
